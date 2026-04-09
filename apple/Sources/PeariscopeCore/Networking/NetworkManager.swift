import Foundation
import Network
import Security
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
    /// Host's Noise public key (set when hosting starts, used for Bonjour LAN discovery)
    @Published public var hostPublicKeyHex: String?
    /// Host's DHT listen port (set when hosting starts, used for Bonjour LAN discovery)
    @Published public var hostDhtPort: UInt16 = 0

    /// OTA update state — drives UI indicators on iOS/macOS.
    public enum OtaStatus: Equatable {
        case idle
        case downloading
        case ready(version: String)
        case applied(version: String)
        case failed(String)
    }
    @Published public var otaStatus: OtaStatus = .idle
    @Published public var connectionPhase: String?
    @Published public var connectionPhaseDetail: String?

    public let bareBridge = BareWorkletBridge()
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
    /// Tracks most recent streamId for each peer key so disconnect cleanup can recover
    /// correct stream IDs even when the disconnect event arrives after peer removal.
    private var peerStreamIds: [String: UInt32] = [:]
    /// When true, ignore incoming peer connections (user explicitly disconnected)
    private var suppressConnections = false
    /// Tracks whether the most recent disconnect was user-initiated (vs stream drop)
    private var _userInitiatedDisconnect = false
    public var isUserInitiatedDisconnect: Bool { _userInitiatedDisconnect }
    public var onVideoData: ((Data) -> Void)?
    public var onAudioData: ((Data) -> Void)?
    public var onInputData: ((Data) -> Void)?

    /// Stream IDs of peers that are blocked from sending input/control/audio data.
    /// HostSession populates this with pending (PIN-unverified) peers.
    /// Checked in onStreamData before dispatching to channel callbacks.
    public var blockedStreamIds: Set<UInt32> = []

    /// Set a direct ch0 video callback on the bridge, bypassing @MainActor isolation.
    /// The callback fires on BareKit's IPC thread. Use for thread-safe decoders.
    public nonisolated func setDirectVideoCallback(_ callback: ((Data) -> Void)?) {
        bareBridge.onCh0VideoData = callback
    }
    /// Buffered control messages that arrived before onControlData was set.
    /// Replayed when the callback is assigned.
    private var pendingControlData: [Data] = []
    public var onControlData: ((Data) -> Void)? {
        didSet {
            NSLog("[net] onControlData didSet: callback=%@, pendingBuffer=%d", onControlData != nil ? "SET" : "NIL", pendingControlData.count)
            if let cb = onControlData, !pendingControlData.isEmpty {
                let buffered = pendingControlData
                pendingControlData.removeAll()
                NSLog("[net] Replaying %d buffered control messages", buffered.count)
                for data in buffered {
                    cb(data)
                }
            } else if onControlData == nil {
                // Clear stale buffered messages so they don't replay on next connect
                pendingControlData.removeAll()
            }
        }
    }
    public var onPeerConnected: ((PeerState) -> Void)?
    public var onPeerDisconnected: ((PeerState) -> Void)?
    public var onJSLog: ((String) -> Void)?
    public var onLookupResult: ((String, Bool) -> Void)?

    public let reconnectionManager = ReconnectionManager()
    public let clipboardSharing = ClipboardSharing()
    private var lastConnectionCode: String?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var networkMonitor: NWPathMonitor?
    private var lastNetworkPath: NWPath?

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
                self.hostPublicKeyHex = event.publicKeyHex
                self.hostDhtPort = event.dhtPort
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
                self.peerStreamIds[event.peerKeyHex] = event.streamId
                self.isConnected = true
                self.isConnecting = false
                self.connectionPhase = nil
                self.connectionPhaseDetail = nil
                self.reconnectionManager.peerReconnected(peerKey: Data(hex: event.peerKeyHex))
                NSLog("[net] isConnected=true, isConnecting=false, peers=%d", self.connectedPeers.count)
                self.onPeerConnected?(peer)
            }
        }

        bareBridge.onPeerDisconnected = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let removedPeer = self.connectedPeers.first { $0.id == event.peerKeyHex }
                self.connectedPeers.removeAll { $0.id == event.peerKeyHex }
                let knownStreamId = self.peerStreamIds.removeValue(forKey: event.peerKeyHex)
                self.isConnected = !self.connectedPeers.isEmpty
                // Always fire onPeerDisconnected — even if peer wasn't in connectedPeers
                // (e.g., pending peer that disconnected before being approved).
                // Create a synthetic PeerState if needed so HostSession can clean up.
                let peer = removedPeer ?? PeerState(id: event.peerKeyHex, name: "", streamId: knownStreamId ?? 0)
                self.onPeerDisconnected?(peer)
                if !self._userInitiatedDisconnect && self.connectedPeers.isEmpty,
                   let code = self.lastConnectionCode {
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
                // Video: onCh0VideoData handles this directly from the bridge.
                // Fall back to onVideoData if set (macOS path).
                // Video is separately gated by HostSession.sendVideoToAllPeers
                // which checks pendingPeerIds before sending. No gate needed here
                // since video flows host→viewer, not viewer→host.
                self.onVideoData?(event.data)
            } else {
                // Block input (ch1) and audio (ch3) from unverified peers.
                // Control (ch2) is allowed through so the viewer's PIN
                // response can reach the host for automatic verification.
                // Other control messages from unverified peers are harmless
                // since no video/audio is flowing to them anyway.
                if event.channel != 2 && self.blockedStreamIds.contains(event.streamId) { return }

                if event.channel == 3 {
                    // Audio: deliver directly without dispatching to main thread.
                    // AudioPlayer is thread-safe and needs low-latency delivery.
                    self.onAudioData?(event.data)
                } else {
                    // Input/control: dispatch to main since handlers update UI state
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        switch event.channel {
                        case 1: self.onInputData?(event.data)
                        case 2:
                            if let cb = self.onControlData {
                                cb(event.data)
                            } else {
                                // Buffer control messages until a handler is set
                                // (e.g. PIN challenge arrives before viewer session exists)
                                self.pendingControlData.append(event.data)
                            }
                        default: break
                        }
                    }
                }
            }
        }

        bareBridge.onConnectionEstablished = { [weak self] event in
            self?.debugLog("[net] Connection established: \(event.peerKeyHex.prefix(16))... streamId=\(event.streamId)")
            // Don't set isConnected here — onPeerConnected handles that atomically
            // with adding the peer to connectedPeers. Setting isConnected here
            // triggers SwiftUI view creation before the peer exists, causing
            // setup() to see peers: 0 and send IDR to nobody.
            Task { @MainActor in
                self?.isConnecting = false
                NSLog("[net] onConnectionEstablished: isConnecting=false (waiting for onPeerConnected)")
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

        bareBridge.onConnectionStatus = { [weak self] phase, detail in
            DispatchQueue.main.async {
                self?.connectionPhase = phase
                self?.connectionPhaseDetail = detail
            }
        }

        bareBridge.onStatusResponse = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                // Recover connectionCode from status if HOSTING_STARTED was lost
                // (IPC backpressure can buffer it behind swarm.join DHT ops)
                if event.isHosting, let code = event.connectionCode, !code.isEmpty, self.connectionCode == nil {
                    self.debugLog("[net] Recovered connectionCode from status response: \(code)")
                    self.isHosting = true
                    self.connectionCode = code
                    UserDefaults.standard.set(code, forKey: "peariscope.lastConnectionWords")
                }
            }
        }

        bareBridge.onDhtNodes = { [weak self] nodes in
            DispatchQueue.main.async {
                guard let self else { return }
                self.mergeDhtNodesCache(nodes)
            }
        }

        bareBridge.onLookupResult = { [weak self] code, online in
            self?.onLookupResult?(code, online)
        }

        bareBridge.onOtaUpdate = { [weak self] version, _ in
            self?.debugLog("[ota] OTA updates disabled for security — ignoring v\(version)")
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

        // Clipboard sharing — text
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

        // Clipboard sharing — images (PNG)
        clipboardSharing.onImageClipboardChanged = { [weak self] pngData in
            guard let self else { return }
            var clipboard = Peariscope_ClipboardData()
            clipboard.imagePng = pngData
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
            case .audio: self?.onAudioData?(event.data)
            case .input: self?.onInputData?(event.data)
            case .control:
                if let cb = self?.onControlData {
                    cb(event.data)
                } else {
                    self?.pendingControlData.append(event.data)
                }
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
            print("[net] System going to sleep, suspending networking")
            self?.clipboardSharing.stopMonitoring()
            self?.suspendNetworking()
        }
        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            print("[net] System woke up, resuming networking")
            self?.clipboardSharing.startMonitoring()
            self?.resumeNetworking()
            Task { @MainActor in
                guard let self else { return }
                if self.isHosting {
                    try? await self.startHosting()
                }
            }
        }
        #endif

        // Monitor network path changes (WiFi reconnect, IP change, etc.)
        // and re-announce DHT topic so the host stays discoverable.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.lastNetworkPath
                self.lastNetworkPath = path

                // Only re-announce if the path actually changed and we're hosting
                guard self.isHosting else { return }
                guard path.status == .satisfied else { return }

                // Skip the initial callback (no previous path)
                guard let prev else { return }

                // Re-announce if interface changed or path was previously unsatisfied
                if prev.status != .satisfied || self.networkInterfacesChanged(prev, path) {
                    self.debugLog("[net] Network path changed, re-announcing DHT topic")
                    self.bareBridge.sendReannounce()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "peariscope.network-monitor"))
        networkMonitor = monitor
    }

    private nonisolated func networkInterfacesChanged(_ old: NWPath, _ new: NWPath) -> Bool {
        let oldIfaces = Set(old.availableInterfaces.map { $0.name })
        let newIfaces = Set(new.availableInterfaces.map { $0.name })
        return oldIfaces != newIfaces
    }

    // MARK: - Runtime startup

    /// Start the Pear runtime. Tries BareKit first, falls back to Node.js on macOS.
    private static let logFile: FileHandle? = {
        let path = NSTemporaryDirectory() + "peariscope-debug.log"
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        return FileHandle(forWritingAtPath: path)
    }()

    private func debugLog(_ msg: String) {
        NSLog("%@", msg)
        // Also fire onJSLog so iOS connecting diagnostics UI shows native logs
        onJSLog?(msg)
        let ts = ISO8601DateFormatter().string(from: Date())
        if let data = "[\(ts)] \(msg)\n".data(using: .utf8) {
            Self.logFile?.seekToEndOfFile()
            Self.logFile?.write(data)
        }
    }

    // MARK: - DHT Keypair Keychain

    /// Load DHT keypair from Keychain.
    static func loadDhtKeypairFromKeychain() -> (publicKey: String, secretKey: String)? {
        let service = "com.peariscope.dht"
        let account = "dht-keypair"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let pub = json["publicKey"], let sec = json["secretKey"] else {
            return nil
        }
        return (publicKey: pub, secretKey: sec)
    }

    // MARK: - DHT Node Cache

    private static let dhtCacheKey = "peariscope.cachedDhtNodes"
    /// Nodes older than 7 days are expired
    private static let dhtNodeMaxAge: TimeInterval = 7 * 24 * 3600 * 1000 // ms (matches JS Date.now())

    /// Merge incoming DHT nodes with existing cache: dedup by host:port,
    /// update lastSeen timestamps, expire stale nodes, prioritize non-standard ports.
    private func mergeDhtNodesCache(_ incoming: [[String: Any]]) {
        // Load existing cache
        var nodeMap: [String: [String: Any]] = [:]
        let existing = Self.loadCachedDhtNodes()
        for node in existing {
            if let host = node["host"] as? String, let port = node["port"] as? Int {
                nodeMap["\(host):\(port)"] = node
            }
        }

        // Merge incoming — newer lastSeen wins
        let now = Date().timeIntervalSince1970 * 1000
        for node in incoming {
            guard let host = node["host"] as? String, let port = node["port"] as? Int else { continue }
            let key = "\(host):\(port)"
            let incomingLastSeen = (node["lastSeen"] as? Double) ?? now
            if let existing = nodeMap[key], let existingLastSeen = existing["lastSeen"] as? Double {
                if incomingLastSeen > existingLastSeen {
                    nodeMap[key] = ["host": host, "port": port, "lastSeen": incomingLastSeen]
                }
            } else {
                nodeMap[key] = ["host": host, "port": port, "lastSeen": incomingLastSeen]
            }
        }

        // Expire old nodes
        let cutoff = now - Self.dhtNodeMaxAge
        var nodes = nodeMap.values.filter { node in
            guard let lastSeen = node["lastSeen"] as? Double else { return false }
            return lastSeen > cutoff
        }

        // Sort: non-standard ports first (CGNAT bypass value), then by recency
        nodes.sort { a, b in
            let aPort = (a["port"] as? Int) ?? 49737
            let bPort = (b["port"] as? Int) ?? 49737
            let aStd = aPort == 49737
            let bStd = bPort == 49737
            if aStd != bStd { return bStd } // non-standard first
            let aTime = (a["lastSeen"] as? Double) ?? 0
            let bTime = (b["lastSeen"] as? Double) ?? 0
            return aTime > bTime
        }

        // Cap at 200 nodes
        if nodes.count > 200 { nodes = Array(nodes.prefix(200)) }

        let nonStd = nodes.filter { ($0["port"] as? Int) != 49737 }.count
        debugLog("[net] DHT cache merged: \(nodes.count) nodes (\(nonStd) non-std ports, expired \(nodeMap.count - nodes.count))")

        if let data = try? JSONSerialization.data(withJSONObject: nodes) {
            UserDefaults.standard.set(data, forKey: Self.dhtCacheKey)
        }
    }

    /// Load cached DHT nodes, filtering expired entries.
    static func loadCachedDhtNodes() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: dhtCacheKey),
              let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let now = Date().timeIntervalSince1970 * 1000
        let cutoff = now - dhtNodeMaxAge
        return nodes.filter { node in
            guard let lastSeen = node["lastSeen"] as? Double else { return true } // keep legacy nodes without timestamps
            return lastSeen > cutoff
        }
    }

    /// Write diagnostic to a file since NSLog is suppressed on iOS 26
    private func diagWrite(_ msg: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let path = docs.appendingPathComponent("peariscope-diag.txt")
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: path)
            }
        }
    }

    public func startRuntime() async throws {
        diagWrite("startRuntime() called, useBareKit=\(useBareKit), isAlive=\(bareBridge.isAlive)")
        debugLog("[net] startRuntime() called")

        // Check if an OTA bundle was applied on this launch
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let otaVersionURL = docsDir.appendingPathComponent("worklet-ota.version")
        let otaBundleURL = docsDir.appendingPathComponent("worklet-ota.bundle")
        if FileManager.default.fileExists(atPath: otaBundleURL.path),
           let version = try? String(contentsOf: otaVersionURL, encoding: .utf8) {
            otaStatus = .applied(version: version)
            debugLog("[ota] Running OTA worklet v\(version)")
            // Delete version file so banner doesn't re-appear on next launch
            try? FileManager.default.removeItem(at: otaVersionURL)
            // Auto-dismiss after 8 seconds
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if case .applied = self.otaStatus { self.otaStatus = .idle }
            }
        }

        // Guard against double-start (e.g. new SwiftUI window re-running .task)
        if useBareKit && bareBridge.isAlive {
            debugLog("[net] startRuntime() skipped — already running")
            return
        }
        // Try BareKit (works on both macOS and iOS)
        let assetsPath = resolvePearAssetsPath()
        diagWrite("assetsPath=\(assetsPath ?? "nil")")
        debugLog("[net] assetsPath: \(assetsPath ?? "nil")")
        if let assetsPath, FileManager.default.fileExists(atPath: assetsPath + "/worklet.bundle") {
            debugLog("[net] worklet.bundle found, starting BareKit...")
            do {
                diagWrite("calling bareBridge.start(assetsPath: \(assetsPath))")
                try bareBridge.start(assetsPath: assetsPath)
                useBareKit = true
                diagWrite("BareKit started OK, isAlive=\(bareBridge.isAlive)")
                debugLog("[net] Started Pear runtime via BareKit")

                // Send cached DHT nodes + keypair to worklet for faster bootstrap
                // and identity persistence (same keypair = same NAT mappings on CGNAT)
                let freshNodes = Self.loadCachedDhtNodes()
                let cachedKeypair: (publicKey: String, secretKey: String)?
                if let kp = Self.loadDhtKeypairFromKeychain(),
                   kp.publicKey.count == 64 && kp.secretKey.count == 128 {
                    cachedKeypair = (publicKey: kp.publicKey, secretKey: kp.secretKey)
                    debugLog("[net] Sending cached keypair: \(kp.publicKey.prefix(16))...")
                } else {
                    cachedKeypair = nil
                }
                if !freshNodes.isEmpty || cachedKeypair != nil {
                    debugLog("[net] Sending \(freshNodes.count) cached DHT nodes to worklet")
                    bareBridge.sendCachedDhtNodes(freshNodes, keypair: cachedKeypair)
                }
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
        _userInitiatedDisconnect = false
        suppressConnections = false
        let newCodeEachSession = UserDefaults.standard.bool(forKey: "peariscope.newCodeEachSession")
        let savedCode = newCodeEachSession ? nil : UserDefaults.standard.string(forKey: "peariscope.lastConnectionWords")
        debugLog("[net] startHosting() called, useBareKit=\(useBareKit), savedCode=\(savedCode ?? "nil")")
        if useBareKit {
            bareBridge.startHosting(deviceCode: savedCode)
            // Retry if connectionCode isn't set within 2 seconds.
            // First try requesting status (recovers code without re-triggering hosting).
            // Only re-send START_HOSTING as last resort.
            Task { @MainActor in
                for attempt in 1...5 {
                    try? await Task.sleep(for: .seconds(2))
                    if self.connectionCode != nil { return }
                    if attempt <= 3 {
                        // Ask for status — worklet may already be hosting but HOSTING_STARTED
                        // was stuck in IPC backpressure behind swarm.join DHT ops
                        self.debugLog("[net] startHosting: requesting status (attempt \(attempt)), connectionCode still nil")
                        self.bareBridge.requestStatus()
                    } else {
                        self.debugLog("[net] startHosting retry \(attempt), connectionCode still nil")
                        self.bareBridge.startHosting(deviceCode: savedCode)
                    }
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
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnecting && lastConnectionCode == normalizedCode {
            debugLog("[net] connect() ignored duplicate request while already connecting")
            return
        }
        _userInitiatedDisconnect = false
        // Clean up any stale state from previous connections before starting new one.
        // This is critical: if the previous peer disconnected on their end, the JS worklet
        // may still have the old swarm topic joined. Without this cleanup, the swarm
        // reconnects to the OLD peer instead of finding the new one.
        reconnectionManager.cancelAll()
        if useBareKit && bareBridge.isAlive {
            bareBridge.disconnectAllPeers()
        }
        connectedPeers.removeAll()
        isConnected = false

        suppressConnections = false
        lastConnectionCode = normalizedCode
        isConnecting = true
        diagWrite("connect() code=\(code.prefix(30))... useBareKit=\(useBareKit) isAlive=\(bareBridge.isAlive)")
        debugLog("[net] connect() called: code=\(code.prefix(30))... useBareKit=\(useBareKit) isAlive=\(bareBridge.isAlive)")
        // Ensure runtime is started — on iOS, startRuntime() is deferred until first connect
        // so useBareKit may still be false here. Start it now if needed.
        if !useBareKit || !bareBridge.isAlive {
            debugLog("[net] Starting/restarting runtime before connect")
            try await startRuntime()
            debugLog("[net] Runtime started, useBareKit=\(useBareKit) isAlive=\(bareBridge.isAlive)")
        }
        if useBareKit {
            debugLog("[net] Sending CONNECT_TO_PEER to worklet")
            bareBridge.connectToPeer(code: normalizedCode)
        } else {
            var connectMsg = Peariscope_ConnectToPeer()
            connectMsg.connectionCode = normalizedCode
            _ = try await ipcClient.request { msg in
                msg.connectToPeer = connectMsg
            }
        }
    }

    /// Connect to a LAN-discovered peer by injecting its local address into the DHT.
    /// Falls back to regular DHT-based connect if host/port are unavailable.
    public func connectLocal(code: String, hostIP: String, dhtPort: UInt16, publicKeyHex: String? = nil) async throws {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnecting && lastConnectionCode == normalizedCode {
            debugLog("[net] connectLocal() ignored duplicate request while already connecting")
            return
        }
        _userInitiatedDisconnect = false
        reconnectionManager.cancelAll()
        if useBareKit && bareBridge.isAlive {
            bareBridge.disconnectAllPeers()
        }
        connectedPeers.removeAll()
        isConnected = false

        suppressConnections = false
        lastConnectionCode = normalizedCode
        isConnecting = true
        debugLog("[net] connectLocal() called: code=\(normalizedCode.prefix(30))... host=\(hostIP):\(dhtPort)")
        if !useBareKit || !bareBridge.isAlive {
            debugLog("[net] Starting/restarting runtime before local connect")
            try await startRuntime()
        }
        if useBareKit {
            bareBridge.connectLocalPeer(code: normalizedCode, host: hostIP, port: dhtPort, publicKeyHex: publicKeyHex)
        } else {
            // Legacy path doesn't support local connect — fall through to DHT
            try await connect(code: normalizedCode)
        }
    }

    /// Managed reconnect loop for viewer-side recovery paths (stale stream, memory pressure).
    /// Centralizes reconnect behavior to avoid multiple competing reconnect loops.
    @discardableResult
    public func reconnect(code: String, maxAttempts: Int = 5) async -> Bool {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else { return false }
        lastConnectionCode = normalizedCode
        for attempt in 1...max(1, maxAttempts) {
            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            do {
                try await connect(code: normalizedCode)
                try? await Task.sleep(for: .seconds(2))
                if !connectedPeers.isEmpty {
                    return true
                }
            } catch {
                debugLog("[net] managed reconnect attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        return false
    }

    /// Connect via TCP relay (legacy, for when BareKit isn't available)
    public func connectViaRelay(host: String, port: UInt16, code: String) async throws {
        try await ipcClient.connectTcp(host: host, port: port)
        print("[net] Connected to relay at \(host):\(port)")
        try await connect(code: code)
    }

    /// Parse a peariscope:// QR URI and connect appropriately
    public func connectFromQR(_ scannedString: String) async throws {
        _userInitiatedDisconnect = false
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

    public func sendAudioData(_ data: Data, streamId: UInt32) throws {
        if useBareKit {
            bareBridge.sendStreamData(streamId: streamId, channel: 3, data: data)
        } else {
            var streamData = Peariscope_StreamData()
            streamData.streamID = streamId
            streamData.channel = .audio
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
        _userInitiatedDisconnect = true
        reconnectionManager.cancelAll()
        lastConnectionCode = nil
        suppressConnections = true
        pendingControlData.removeAll()
        // Always tell JS to disconnect all peers and leave all swarm topics.
        // connectedPeers may already be empty (peer disconnected before us),
        // but JS may still have the topic joined → stale reconnections.
        if useBareKit && bareBridge.isAlive {
            bareBridge.disconnectAllPeers()
        }
        connectedPeers.removeAll()
        peerStreamIds.removeAll()
        blockedStreamIds.removeAll()
        isConnected = false
        isConnecting = false
        connectionPhase = nil
        connectionPhaseDetail = nil
        // suppressConnections stays true until the next explicit connect() or
        // startHosting() call. This prevents Hyperswarm from re-establishing
        // the connection after the user explicitly disconnects.
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

    public func suspendNetworking() {
        bareBridge.sendSuspend()
        debugLog("[net] Sent suspend to worklet")
    }

    public func resumeNetworking() {
        bareBridge.sendResume()
        debugLog("[net] Sent resume to worklet")
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
