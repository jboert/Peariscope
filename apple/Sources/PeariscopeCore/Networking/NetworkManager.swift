import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// High-level manager that coordinates the Pear runtime (via BareKit) for P2P networking.
/// Uses BareWorkletBridge on both macOS and iOS for true peer-to-peer connections.
@MainActor
public final class NetworkManager: ObservableObject {
    @Published public var isHosting = false
    @Published public var isConnected = false
    @Published public var isConnecting = false
    @Published public var connectionCode: String?
    @Published public var deviceCode: String {
        didSet { UserDefaults.standard.set(deviceCode, forKey: "peariscope.deviceCode") }
    }
    @Published public var relayHost: String?
    @Published public var relayPort: UInt32?
    @Published public var connectedPeers: [PeerState] = []
    @Published public var lastError: String?

    private let bareBridge = BareWorkletBridge()
    // Keep legacy IPC client for fallback if BareKit isn't available
    private let ipcClient: IpcClient
    #if os(macOS)
    private let pearProcess: PearProcess
    #endif
    private var useBareKit = false

    public struct PeerState: Identifiable {
        public let id: String  // hex public key
        public let name: String
        public let streamId: UInt32
    }

    private var streamDataCount = 0
    /// When true, ignore incoming peer connections (user explicitly disconnected)
    private var suppressConnections = false
    public var onVideoData: ((Data) -> Void)?
    public var onInputData: ((Data) -> Void)?
    public var onControlData: ((Data) -> Void)?
    public var onPeerConnected: ((PeerState) -> Void)?
    public var onPeerDisconnected: ((PeerState) -> Void)?
    public var onJSLog: ((String) -> Void)?
    public var onLookupResult: ((String, Bool) -> Void)?

    public let reconnectionManager = ReconnectionManager()
    public let clipboardSharing = ClipboardSharing()
    private var lastConnectionCode: String?
    private var sleepObserver: Any?
    private var wakeObserver: Any?

    public init() {
        // Load or generate persistent device code
        if let saved = UserDefaults.standard.string(forKey: "peariscope.deviceCode"), saved.count == 24 {
            self.deviceCode = saved
        } else {
            // Generate a random 24-char code
            let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no ambiguous chars (0/O, 1/I)
            let code = String((0..<24).map { _ in chars.randomElement()! })
            self.deviceCode = code
            UserDefaults.standard.set(code, forKey: "peariscope.deviceCode")
        }

        #if os(macOS)
        let bundledPearDir = Bundle.main.bundlePath + "/Contents/Resources/pear"
        let pearDir: String
        if FileManager.default.fileExists(atPath: bundledPearDir + "/index.js") {
            pearDir = bundledPearDir
        } else {
            pearDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("pear")
                .path
        }
        self.pearProcess = PearProcess(pearDir: pearDir)
        #endif
        self.ipcClient = IpcClient()

        setupBareCallbacks()
        setupLegacyCallbacks()
    }

    // MARK: - BareKit callbacks

    private func setupBareCallbacks() {
        bareBridge.onHostingStarted = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.isHosting = true
                self.connectionCode = event.connectionCode
                UserDefaults.standard.set(event.connectionCode, forKey: "peariscope.lastConnectionWords")
            }
        }

        bareBridge.onHostingStopped = { [weak self] in
            Task { @MainActor in
                self?.isHosting = false
                self?.connectionCode = nil
            }
        }

        bareBridge.onPeerConnected = { [weak self] event in
            self?.debugLog("[net] Peer connected: \(event.peerKeyHex.prefix(16))... streamId=\(event.streamId) suppressConnections=\(self?.suppressConnections ?? false)")
            Task { @MainActor in
                guard let self else {
                    NSLog("[net] onPeerConnected: self is nil, ignoring")
                    return
                }
                guard !self.suppressConnections else {
                    NSLog("[net] onPeerConnected: suppressConnections=true, ignoring peer")
                    return
                }
                let peer = PeerState(
                    id: event.peerKeyHex,
                    name: event.peerName,
                    streamId: event.streamId
                )
                self.connectedPeers.append(peer)
                self.isConnected = true
                self.isConnecting = false
                NSLog("[net] isConnected=true, isConnecting=false, peers=%d", self.connectedPeers.count)
                self.onPeerConnected?(peer)
            }
        }

        bareBridge.onPeerDisconnected = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let removedPeer = self.connectedPeers.first { $0.id == event.peerKeyHex }
                self.connectedPeers.removeAll { $0.id == event.peerKeyHex }
                self.isConnected = !self.connectedPeers.isEmpty
                if let removedPeer {
                    self.onPeerDisconnected?(removedPeer)
                }
                if let code = self.lastConnectionCode {
                    self.reconnectionManager.peerDisconnected(
                        code: code,
                        peerKey: Data(hex: event.peerKeyHex)
                    )
                }
            }
        }

        bareBridge.onStreamData = { [weak self] event in
            guard let self else { return }
            if event.channel == 0 {
                // Video: call directly from IPC thread to avoid unbounded main queue
                // closure accumulation during burst delivery. decoder.decode() handles
                // its own threading via serial queue + depth limiting.
                self.onVideoData?(event.data)
            } else {
                // Input/control: dispatch to main since handlers update UI state
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch event.channel {
                    case 1: self.onInputData?(event.data)
                    case 2: self.onControlData?(event.data)
                    default: break
                    }
                }
            }
        }

        bareBridge.onConnectionEstablished = { [weak self] event in
            self?.debugLog("[net] Connection established: \(event.peerKeyHex.prefix(16))... streamId=\(event.streamId)")
            Task { @MainActor in
                self?.isConnected = true
                self?.isConnecting = false
                NSLog("[net] onConnectionEstablished: isConnected=true, isConnecting=false")
            }
        }

        bareBridge.onConnectionFailed = { [weak self] event in
            Task { @MainActor in
                self?.lastError = "Connection failed: \(event.reason)"
                self?.isConnecting = false
            }
        }

        bareBridge.onError = { [weak self] message in
            NSLog("[bare] ERROR: %@", message)
            Task { @MainActor in
                self?.lastError = message
            }
        }

        bareBridge.onLog = { [weak self] message in
            self?.debugLog("[bare-js] \(message)")
            self?.onJSLog?(message)
        }

        bareBridge.onLookupResult = { [weak self] code, online in
            self?.onLookupResult?(code, online)
        }

        // Reconnection handler
        reconnectionManager.onReconnectAttempt = { [weak self] record in
            Task { @MainActor in
                guard let self else { return }
                print("[net] Reconnection attempt \(record.attempts) for \(record.connectionCode)")
                try? await self.connect(code: record.connectionCode)
            }
        }

        reconnectionManager.onReconnectGaveUp = { [weak self] record in
            Task { @MainActor in
                self?.lastError = "Failed to reconnect after \(record.attempts) attempts"
            }
        }

        // Clipboard sharing
        clipboardSharing.onClipboardChanged = { [weak self] text in
            guard let self else { return }
            var clipboard = Peariscope_ClipboardData()
            clipboard.text = text
            var control = Peariscope_ControlMessage()
            control.clipboard = clipboard
            guard let data = try? control.serializedData() else { return }
            for peer in self.connectedPeers {
                try? self.sendControlData(data, streamId: peer.streamId)
            }
        }

        setupSleepWakeObservers()
    }

    // MARK: - Legacy IPC callbacks (for Node.js fallback)

    private func setupLegacyCallbacks() {
        #if os(macOS)
        pearProcess.onOutput = { line in
            print("[pear-out] \(line)", terminator: "")
        }

        pearProcess.onTerminated = { [weak self] status in
            print("[pear] Process terminated with status: \(status)")
            Task { @MainActor in
                self?.isHosting = false
                self?.isConnected = false
            }
        }
        #endif

        ipcClient.onPeerConnected = { [weak self] event in
            Task { @MainActor in
                let peer = PeerState(
                    id: event.peerKey.map { String(format: "%02x", $0) }.joined(),
                    name: event.peerName,
                    streamId: event.streamID
                )
                self?.connectedPeers.append(peer)
                self?.isConnected = true
                self?.reconnectionManager.peerReconnected(peerKey: event.peerKey)
                self?.onPeerConnected?(peer)
            }
        }

        ipcClient.onPeerDisconnected = { [weak self] event in
            let keyHex = event.peerKey.map { String(format: "%02x", $0) }.joined()
            Task { @MainActor in
                guard let self else { return }
                let removedPeer = self.connectedPeers.first { $0.id == keyHex }
                self.connectedPeers.removeAll { $0.id == keyHex }
                self.isConnected = !self.connectedPeers.isEmpty
                if let removedPeer {
                    self.onPeerDisconnected?(removedPeer)
                }
                if let code = self.lastConnectionCode {
                    self.reconnectionManager.peerDisconnected(code: code, peerKey: event.peerKey)
                }
            }
        }

        ipcClient.onStreamData = { [weak self] event in
            switch event.channel {
            case .video: self?.onVideoData?(event.data)
            case .input: self?.onInputData?(event.data)
            case .control: self?.onControlData?(event.data)
            default: break
            }
        }

        ipcClient.onConnectionFailed = { [weak self] event in
            Task { @MainActor in
                self?.lastError = "Connection failed: \(event.reason)"
            }
        }
    }

    private func setupSleepWakeObservers() {
        #if os(macOS)
        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            print("[net] System going to sleep, pausing connections")
            self?.clipboardSharing.stopMonitoring()
        }
        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            print("[net] System woke up, resuming connections")
            self?.clipboardSharing.startMonitoring()
            Task { @MainActor in
                guard let self else { return }
                if self.isHosting {
                    try? await self.startHosting()
                }
            }
        }
        #endif
    }

    // MARK: - Runtime startup

    /// Start the Pear runtime. Tries BareKit first, falls back to Node.js on macOS.
    private static let logFile: FileHandle? = {
        let path = "/tmp/peariscope-debug.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private func debugLog(_ msg: String) {
        NSLog("%@", msg)
        let ts = ISO8601DateFormatter().string(from: Date())
        if let data = "[\(ts)] \(msg)\n".data(using: .utf8) {
            Self.logFile?.seekToEndOfFile()
            Self.logFile?.write(data)
        }
    }

    public func startRuntime() async throws {
        debugLog("[net] startRuntime() called")
        // Guard against double-start (e.g. new SwiftUI window re-running .task)
        if useBareKit && bareBridge.isAlive {
            debugLog("[net] startRuntime() skipped — already running")
            return
        }
        // Try BareKit (works on both macOS and iOS)
        let assetsPath = resolvePearAssetsPath()
        debugLog("[net] assetsPath: \(assetsPath ?? "nil")")
        if let assetsPath, FileManager.default.fileExists(atPath: assetsPath + "/worklet.bundle") {
            debugLog("[net] worklet.bundle found, starting BareKit...")
            do {
                try bareBridge.start(assetsPath: assetsPath)
                useBareKit = true
                debugLog("[net] Started Pear runtime via BareKit")
                return
            } catch {
                debugLog("[net] BareKit failed: \(error.localizedDescription)")
            }
        } else {
            debugLog("[net] worklet.bundle NOT found at assetsPath")
        }

        // Fallback: Node.js subprocess (macOS only)
        #if os(macOS)
        try pearProcess.start()
        try await Task.sleep(for: .seconds(2))
        try await ipcClient.connect()
        useBareKit = false
        print("[net] Connected to Pear runtime via Node.js")
        #else
        throw NetworkError.noPearRuntime
        #endif
    }

    private func resolvePearAssetsPath() -> String? {
        // Check app bundle first
        #if os(macOS)
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/pear"
        #else
        let bundled = Bundle.main.bundlePath + "/pear"
        #endif
        if FileManager.default.fileExists(atPath: bundled + "/worklet.bundle") {
            return bundled
        }

        // Check source tree (development)
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pear")
            .path
        if FileManager.default.fileExists(atPath: sourceTree + "/worklet.bundle") {
            return sourceTree
        }

        return nil
    }

    // MARK: - Hosting

    public func startHosting() async throws {
        suppressConnections = false
        let newCodeEachSession = UserDefaults.standard.bool(forKey: "peariscope.newCodeEachSession")
        let savedCode = newCodeEachSession ? nil : UserDefaults.standard.string(forKey: "peariscope.lastConnectionWords")
        debugLog("[net] startHosting() called, useBareKit=\(useBareKit), savedCode=\(savedCode ?? "nil")")
        if useBareKit {
            bareBridge.startHosting(deviceCode: savedCode)
            // Retry if connectionCode isn't set within 2 seconds
            // (IPC command can get lost among video frame flood)
            Task { @MainActor in
                for attempt in 1...3 {
                    try? await Task.sleep(for: .seconds(2))
                    if self.connectionCode != nil { return }
                    self.debugLog("[net] startHosting retry \(attempt), connectionCode still nil")
                    self.bareBridge.startHosting(deviceCode: savedCode)
                }
            }
        } else {
            let response = try await ipcClient.request { msg in
                msg.startHosting = Peariscope_StartHosting()
            }
            if case .hostingStarted(let event) = response.payload {
                isHosting = true
                connectionCode = event.connectionCode
                relayHost = event.relayHost
                relayPort = event.relayPort
            }
        }
    }

    public func regenerateCode() async throws {
        UserDefaults.standard.removeObject(forKey: "peariscope.lastConnectionWords")
        try await stopHosting()
        try await startHosting()
    }

    public func stopHosting() async throws {
        debugLog("[net] stopHosting() called, useBareKit=\(useBareKit)")
        if useBareKit {
            bareBridge.stopHosting()
            isHosting = false
            connectionCode = nil
        } else {
            _ = try await ipcClient.request { msg in
                msg.stopHosting = Peariscope_StopHosting()
            }
            isHosting = false
            connectionCode = nil
        }
    }

    // MARK: - Connecting

    public func connect(code: String) async throws {
        suppressConnections = false
        lastConnectionCode = code
        isConnecting = true
        if useBareKit {
            // Restart worklet if it was terminated (e.g. by memory pressure)
            if !bareBridge.isAlive {
                NSLog("[net] Worklet is dead, restarting runtime before connect")
                try await startRuntime()
            }
            bareBridge.connectToPeer(code: code)
        } else {
            var connectMsg = Peariscope_ConnectToPeer()
            connectMsg.connectionCode = code
            _ = try await ipcClient.request { msg in
                msg.connectToPeer = connectMsg
            }
        }
    }

    /// Connect via TCP relay (legacy, for when BareKit isn't available)
    public func connectViaRelay(host: String, port: UInt16, code: String) async throws {
        try await ipcClient.connectTcp(host: host, port: port)
        print("[net] Connected to relay at \(host):\(port)")
        try await connect(code: code)
    }

    /// Parse a peariscope:// QR URI and connect appropriately
    public func connectFromQR(_ scannedString: String) async throws {
        if scannedString.hasPrefix("peariscope://relay?") {
            guard let url = URL(string: scannedString),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let host = components.queryItems?.first(where: { $0.name == "host" })?.value,
                  let portStr = components.queryItems?.first(where: { $0.name == "port" })?.value,
                  let port = UInt16(portStr)
            else {
                throw IpcError.urlParsingFailed(scannedString)
            }

            if useBareKit {
                // With BareKit, just connect using the code — P2P, no relay needed
                try await connect(code: code)
            } else {
                try await connectViaRelay(host: host, port: port, code: code)
            }
        } else {
            try await connect(code: scannedString)
        }
    }

    // MARK: - Data sending

    public func sendVideoData(_ data: Data, streamId: UInt32) throws {
        if useBareKit {
            bareBridge.sendStreamData(streamId: streamId, channel: 0, data: data)
        } else {
            var streamData = Peariscope_StreamData()
            streamData.streamID = streamId
            streamData.channel = .video
            streamData.data = data
            var msg = Peariscope_IpcMessage()
            msg.streamData = streamData
            try ipcClient.send(msg)
        }
    }

    public func sendInputData(_ data: Data, streamId: UInt32) throws {
        if useBareKit {
            bareBridge.sendStreamData(streamId: streamId, channel: 1, data: data)
        } else {
            var streamData = Peariscope_StreamData()
            streamData.streamID = streamId
            streamData.channel = .input
            streamData.data = data
            var msg = Peariscope_IpcMessage()
            msg.streamData = streamData
            try ipcClient.send(msg)
        }
    }

    public func sendControlData(_ data: Data, streamId: UInt32) throws {
        if useBareKit {
            bareBridge.sendStreamData(streamId: streamId, channel: 2, data: data)
        } else {
            var streamData = Peariscope_StreamData()
            streamData.streamID = streamId
            streamData.channel = .control
            streamData.data = data
            var msg = Peariscope_IpcMessage()
            msg.streamData = streamData
            try ipcClient.send(msg)
        }
    }

    // MARK: - Disconnect

    public func disconnectAll() {
        reconnectionManager.cancelAll()
        lastConnectionCode = nil
        suppressConnections = true
        for peer in connectedPeers {
            if useBareKit {
                bareBridge.disconnect(peerKeyHex: peer.id)
            }
        }
        connectedPeers.removeAll()
        isConnected = false
        isConnecting = false
    }

    public func disconnect(peerKey: Data) async throws {
        if useBareKit {
            let hex = peerKey.map { String(format: "%02x", $0) }.joined()
            bareBridge.disconnect(peerKeyHex: hex)
        } else {
            var disconnectMsg = Peariscope_Disconnect()
            disconnectMsg.peerKey = peerKey
            _ = try await ipcClient.request { msg in
                msg.disconnect = disconnectMsg
            }
        }
    }

    // MARK: - Shutdown

    public func shutdown() {
        reconnectionManager.cancelAll()
        clipboardSharing.stopMonitoring()

        if useBareKit {
            bareBridge.terminate()
        } else {
            ipcClient.disconnect()
            #if os(macOS)
            pearProcess.stop()
            #endif
        }

        #if os(macOS)
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        #endif
    }

    /// Whether the BareKit worklet is running.
    public var isWorkletAlive: Bool { bareBridge.isAlive }

    /// DHT lookup to check if a peer is online without connecting.
    public func lookupPeer(code: String) {
        guard useBareKit else { return }
        bareBridge.lookupPeer(code: code)
    }

    /// Diagnostic summary from the BareWorkletBridge.
    public func bridgeDiagnosticSummary() -> String {
        return bareBridge.diagnosticSummary()
    }

    /// Suspend the BareKit worklet to stop all network I/O and reduce memory pressure.
    public func suspendWorklet() {
        if useBareKit {
            bareBridge.suspend()
            debugLog("[net] BareKit worklet suspended")
        }
    }

    /// Resume a previously suspended BareKit worklet.
    public func resumeWorklet() {
        if useBareKit {
            bareBridge.resume()
            debugLog("[net] BareKit worklet resumed")
        }
    }

    public func enableClipboardSharing() {
        clipboardSharing.startMonitoring()
    }

    public func disableClipboardSharing() {
        clipboardSharing.stopMonitoring()
    }
}

// MARK: - Errors

public enum NetworkError: LocalizedError {
    case noPearRuntime

    public var errorDescription: String? {
        switch self {
        case .noPearRuntime:
            return "No Pear runtime available. BareKit worklet.bundle not found."
        }
    }
}

// MARK: - Data hex helper

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                append(byte)
            }
            index = nextIndex
        }
    }
}
