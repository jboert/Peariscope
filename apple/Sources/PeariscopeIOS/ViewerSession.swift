#if os(iOS)
import SwiftUI
import MetalKit
import CoreMedia
import UIKit
import PeariscopeCore

// MARK: - iOS Viewer Session

@MainActor
final class IOSViewerSession: ObservableObject {
    @Published var isActive = false
    @Published var fps: Double = 0
    @Published var latencyMs: Double = 0
    @Published var isTrackpadMode = true
    @Published var isReconnecting = false
    @Published var connectionLost = false  // true when all reconnect attempts failed
    @Published var hasReceivedFirstFrame = false
    @Published var availableDisplays: [Peariscope_DisplayInfo] = []
    @Published var activeDisplayId: UInt32 = 0
    @Published var pendingPin: String?
    @Published var pinEntryText: String = ""
    @Published var hostFingerprint: String?
    /// Remote cursor position from host (normalized 0-1)
    /// NOT @Published — updated at high frequency, would cause excessive SwiftUI re-renders
    var remoteCursorX: Float = 0.5
    var remoteCursorY: Float = 0.5

    /// Called when the viewer should exit back to the connect screen.
    /// ONLY called by explicit user action (disconnect button, PIN cancel).
    var onExitViewer: (() -> Void)?

    /// Tracks whether we've suspended the worklet due to memory pressure
    private var workletSuspendedForMemory = false

    private var h264Decoder: H264Decoder?
    private var h265Decoder: H265Decoder?
    private(set) var renderer: MetalRenderer?
    let networkManager: NetworkManager
    private let latencyTracker = LatencyTracker()
    private var detectedH265 = false

    private var frameCountInInterval = 0
    private var idrRetryCount = 0
    private var fpsTimer: Timer?
    private var qualityReportTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryWarningObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var currentThermalState: ProcessInfo.ThermalState = .nominal
    private var lastFrameTime: Date = Date()
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    var cursorX: Float = 0.5
    var cursorY: Float = 0.5
    weak var mtkView: MTKView?

    /// [6] Last connection code for auto-reconnect
    private var lastCode: String?

    /// User-applied zoom multiplier (1.0 = fit, >1.0 = zoomed in)
    var userZoom: Float = 1.0
    /// User pan offset (in normalized coords, applied on top of cursor-follow)
    var userPanOffset: SIMD2<Float> = .zero

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }


    func setup(mtkView: MTKView) {
        NSLog("[viewer] setup() called, creating decoders and renderer")
        // Reset static counters so FIRST VIDEO DATA logs each time
        IOSViewerSession.routeCount = 0
        IOSViewerSession.routeBytes = 0
        // Stop any existing decoders to prevent dangling Unmanaged pointers
        // in VT decompression callbacks if setup() is called more than once
        h264Decoder?.stop()
        h265Decoder?.stop()
        renderer?.stop()
        let h264 = H264Decoder()
        let h265 = H265Decoder()
        renderer = MetalRenderer(mtkView: mtkView)
        self.mtkView = mtkView

        // Direct delivery: decoder → renderer, no intermediate buffering.
        // Capture the renderer directly to avoid accessing @MainActor-isolated
        // `self.renderer` from VideoToolbox's decoder thread (data race).
        let metalRenderer = renderer
        let onDecoded: (CVPixelBuffer, CMTime) -> Void = { [weak self] pixelBuffer, _ in
            // renderer.display() is thread-safe (NSLock), safe from VT thread
            metalRenderer?.display(pixelBuffer: pixelBuffer)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.hasReceivedFirstFrame {
                    self.hasReceivedFirstFrame = true
                }
                self.lastFrameTime = Date()
                if self.textureWidth != w || self.textureHeight != h {
                    self.textureWidth = w
                    self.textureHeight = h
                    self.updateViewport()
                }
                self.frameCountInInterval += 1
            }
        }

        h264.onDecodedFrame = onDecoded
        h265.onDecodedFrame = onDecoded
        h264Decoder = h264
        h265Decoder = h265

        networkManager.onJSLog = { msg in
            CrashLog.write("JS: \(msg)")
        }

        networkManager.onVideoData = { [weak self] data in
            // Log first video data arrival for diagnostics
            if IOSViewerSession.routeCount == 0 {
                let availMB = os_proc_available_memory() / 1_048_576
                CrashLog.write("FIRST VIDEO DATA: len=\(data.count) mem=\(availMB)MB")
            }
            self?.routeVideoData(data)
        }

        networkManager.onControlData = { [weak self] data in
            guard let self else { return }
            if let msg = try? Peariscope_ControlMessage(serializedBytes: data) {
                self.handleControlMessage(msg)
            }
        }

        // [6] Auto-reconnect: listen for peer disconnect
        networkManager.onPeerDisconnected = { [weak self] peer in
            guard let self else { return }
            Task { @MainActor in
                self.attemptReconnect()
            }
        }

        isActive = true
        requestIDR()
        CrashLog.write("setup() complete: isActive=true, h264=\(h264Decoder != nil) h265=\(h265Decoder != nil) renderer=\(renderer != nil) onVideoData=\(networkManager.onVideoData != nil)")

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let frames = self.frameCountInInterval
                self.fps = Double(frames)
                self.frameCountInInterval = 0
                self.latencyMs = self.latencyTracker.averageLatencyMs
                // Heartbeat to persistent crash log — if the app dies,
                // the last heartbeat tells us exactly when and memory state
                let availMB = os_proc_available_memory() / 1_048_576
                CrashLog.write("heartbeat: fps=\(frames) mem=\(availMB)MB tex=\(self.textureWidth)x\(self.textureHeight)")
                // Extended diagnostics: decoder, renderer, and IPC stats
                if let h265Diag = self.h265Decoder?.diagnosticSummary() {
                    CrashLog.write("  h265: \(h265Diag)")
                }
                if let rendererDiag = self.renderer?.diagnosticSummary() {
                    CrashLog.write("  renderer: \(rendererDiag)")
                }
                CrashLog.write("  bridge: \(self.networkManager.bridgeDiagnosticSummary())")
                if availMB > 0 && availMB < 100 {
                    CrashLog.write("LOW MEMORY: \(availMB)MB — jetsam kill imminent")
                }
                // Terminate BareKit worklet when memory is critically low.
                // DON'T exit the viewer — stay visible and auto-reconnect.
                // Exiting causes "Connecting..." screen flicker as the view cycles.
                if availMB > 0 && availMB < 150 && !self.workletSuspendedForMemory {
                    CrashLog.write("TERMINATING WORKLET (heartbeat): mem=\(availMB)MB — killing V8, will reconnect")
                    self.handleMemoryPressure()
                }
                // If no frames decoded for 2+ seconds, re-request keyframe
                if frames == 0 && self.isActive && self.pendingPin == nil {
                    self.idrRetryCount += 1
                    if self.idrRetryCount >= 2 && self.idrRetryCount <= 10 {
                        NSLog("[viewer] No frames for %d seconds, re-requesting IDR", self.idrRetryCount)
                        self.requestIDR()
                    }
                    // Stale connection: no frames for 15+ seconds after first frame
                    // means the host is gone but the stream didn't close cleanly
                    if self.idrRetryCount >= 15 && self.hasReceivedFirstFrame && !self.isReconnecting {
                        CrashLog.write("STALE CONNECTION: no frames for \(self.idrRetryCount)s — triggering reconnect")
                        self.attemptReconnect()
                    }
                } else if frames > 0 {
                    self.idrRetryCount = 0
                }
            }
        }

        // [14] Quality report timer — send stats to host every 2 seconds for adaptive bitrate
        qualityReportTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sendQualityReport()
            }
        }

        // [15] Immediate memory pressure response — terminates worklet on critical
        // pressure instead of waiting for the heartbeat (1/sec). At 650MB/sec memory
        // drain from UDX/V8, the heartbeat is too slow to prevent jetsam.
        // DON'T exit the viewer — stay visible and auto-reconnect to avoid
        // "Connecting..." screen flicker.
        let memSource = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        memSource.setEventHandler { [weak self] in
            guard let self, self.isActive, !self.workletSuspendedForMemory else { return }
            let availMB = os_proc_available_memory() / 1_048_576
            CrashLog.write("MEMORY PRESSURE CRITICAL: \(availMB)MB — terminating worklet, will reconnect")
            self.handleMemoryPressure()
        }
        memSource.resume()
        memoryPressureSource = memSource

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, !self.workletSuspendedForMemory else { return }
            let availMB = os_proc_available_memory() / 1_048_576
            if availMB > 0 && availMB < 200 {
                CrashLog.write("UIKit MEMORY WARNING: \(availMB)MB — terminating worklet, will reconnect")
                self.handleMemoryPressure()
            }
        }

        // [16] Detect stale connection when returning from background.
        // If no frames received for >5s after foregrounding, the connection
        // is dead — exit the viewer so the user can reconnect.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, self.hasReceivedFirstFrame else { return }
                let staleSec = Date().timeIntervalSince(self.lastFrameTime)
                CrashLog.write("FOREGROUND: last frame \(String(format: "%.1f", staleSec))s ago, peers=\(self.networkManager.connectedPeers.count)")
                if staleSec > 5 {
                    // Connection is stale — try IDR first, then exit if still no frames
                    self.requestIDR()
                    try? await Task.sleep(for: .seconds(3))
                    guard self.isActive else { return }
                    let newStaleSec = Date().timeIntervalSince(self.lastFrameTime)
                    if newStaleSec > 3 {
                        CrashLog.write("FOREGROUND: connection stale (\(String(format: "%.1f", newStaleSec))s), exiting viewer")
                        self.disconnect()
                        self.onExitViewer?()
                    }
                }
            }
        }

        // [17] Thermal throttling — reduce FPS/bitrate when device gets hot
        currentThermalState = ProcessInfo.processInfo.thermalState
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            let state = ProcessInfo.processInfo.thermalState
            self.currentThermalState = state
            let stateName: String
            switch state {
            case .nominal: stateName = "nominal"
            case .fair: stateName = "fair"
            case .serious: stateName = "serious"
            case .critical: stateName = "critical"
            @unknown default: stateName = "unknown"
            }
            CrashLog.write("THERMAL: state=\(stateName)")
            self.sendThermalQualityHint()
        }
    }

    /// Send quality hint to host based on thermal state
    private func sendThermalQualityHint() {
        var report = Peariscope_QualityReport()
        report.fps = UInt32(fps)
        report.rttMs = UInt32(latencyMs)
        let screen = UIScreen.main.nativeBounds
        report.screenWidth = UInt32(screen.width)
        report.screenHeight = UInt32(screen.height)
        switch currentThermalState {
        case .nominal, .fair:
            report.bitrateKbps = 0  // no restriction
        case .serious:
            report.bitrateKbps = 4000  // request 4Mbps max
            report.fps = 30  // request 30fps
        case .critical:
            report.bitrateKbps = 2000  // request 2Mbps max
            report.fps = 15  // request 15fps
        @unknown default:
            break
        }
        var control = Peariscope_ControlMessage()
        control.qualityReport = report
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    // [6] Handle memory pressure — terminate worklet but stay in viewer, reconnect
    private func handleMemoryPressure() {
        guard !workletSuspendedForMemory else { return }
        workletSuspendedForMemory = true
        // Kill the worklet to free V8/libuv memory, but DON'T exit the viewer.
        // Clear video/control callbacks to stop data flow, but keep onPeerDisconnected
        // so we detect when the connection is fully dead.
        networkManager.onVideoData = nil
        networkManager.onControlData = nil
        h264Decoder?.stop()
        h264Decoder = nil
        h265Decoder?.stop()
        h265Decoder = nil
        networkManager.shutdown()
        networkManager.connectedPeers.removeAll()
        networkManager.isConnected = false
        networkManager.isConnecting = false
        // Don't call onExitViewer — stay in viewer, show reconnecting banner
        isReconnecting = true
        CrashLog.write("MEMORY PRESSURE: worklet terminated, starting reconnect in 3s")
        Task {
            // Wait for memory to recover after V8 teardown
            try? await Task.sleep(for: .seconds(3))
            guard isReconnecting else { return }
            workletSuspendedForMemory = false
            reconnectAfterPressure()
        }
    }

    // [6] Auto-reconnect (from peer disconnect or memory pressure)
    private func reconnectAfterPressure() {
        guard let code = lastCode, isReconnecting else {
            isReconnecting = false
            return
        }
        let availMB = os_proc_available_memory() / 1_048_576
        CrashLog.write("RECONNECT-AFTER-PRESSURE: mem=\(availMB)MB code=\(code.prefix(20))...")
        Task {
            for attempt in 1...5 {
                guard isReconnecting else { return }
                let availMB = os_proc_available_memory() / 1_048_576
                CrashLog.write("RECONNECT attempt \(attempt): mem=\(availMB)MB")
                do {
                    try await networkManager.connectFromQR(code)
                    try? await Task.sleep(for: .seconds(3))
                    if !networkManager.connectedPeers.isEmpty {
                        CrashLog.write("RECONNECT success on attempt \(attempt)")
                        isReconnecting = false
                        // Re-setup decoders since they were stopped
                        if let mtkView = self.mtkView {
                            setup(mtkView: mtkView)
                        }
                        return
                    }
                } catch {
                    CrashLog.write("RECONNECT attempt \(attempt) failed: \(error)")
                }
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
            CrashLog.write("RECONNECT gave up after 5 attempts")
            isReconnecting = false
            connectionLost = true
        }
    }

    private func attemptReconnect() {
        guard let code = lastCode, !isReconnecting else { return }
        // Only reconnect if we were actively viewing and peers dropped to 0
        guard networkManager.connectedPeers.isEmpty, isActive else { return }
        isReconnecting = true
        connectionLost = false
        let availMB = os_proc_available_memory() / 1_048_576
        CrashLog.write("AUTO-RECONNECT starting: mem=\(availMB)MB code=\(code.prefix(20))...")
        NSLog("[viewer] Connection lost, attempting auto-reconnect with code: %@", code)
        Task {
            for attempt in 1...5 {
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                guard isReconnecting else { return } // user may have manually disconnected
                NSLog("[viewer] Reconnect attempt %d", attempt)
                do {
                    try await networkManager.connectFromQR(code)
                    // Wait a moment for connection to establish
                    try? await Task.sleep(for: .seconds(2))
                    if !networkManager.connectedPeers.isEmpty {
                        NSLog("[viewer] Reconnected successfully")
                        isReconnecting = false
                        requestIDR()
                        return
                    }
                } catch {
                    NSLog("[viewer] Reconnect attempt %d failed: %@", attempt, error.localizedDescription)
                }
            }
            NSLog("[viewer] Auto-reconnect gave up after 5 attempts")
            isReconnecting = false
            connectionLost = true
        }
    }

    func setLastCode(_ code: String) {
        lastCode = code
    }

    // [14] Send quality report to host for adaptive bitrate
    private func sendQualityReport() {
        var report = Peariscope_QualityReport()
        report.fps = UInt32(fps)
        report.rttMs = UInt32(latencyMs)
        report.bitrateKbps = 0
        // Send native screen resolution so host can downscale capture
        let screen = UIScreen.main.nativeBounds
        report.screenWidth = UInt32(screen.width)
        report.screenHeight = UInt32(screen.height)

        var control = Peariscope_ControlMessage()
        control.qualityReport = report

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    func disconnect() {
        isReconnecting = false
        fpsTimer?.invalidate()
        fpsTimer = nil
        qualityReportTimer?.invalidate()
        qualityReportTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let obs = memoryWarningObserver {
            NotificationCenter.default.removeObserver(obs)
            memoryWarningObserver = nil
        }
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        if let obs = thermalObserver {
            NotificationCenter.default.removeObserver(obs)
            thermalObserver = nil
        }
        // Clear callbacks first to stop new data flowing in
        networkManager.onVideoData = nil
        networkManager.onControlData = nil
        networkManager.onPeerDisconnected = nil
        // Stop decoders first — this waits for pending VT frames, ensuring
        // no more onDecodedFrame callbacks will fire after this returns
        h264Decoder?.stop()
        h264Decoder = nil
        h265Decoder?.stop()
        h265Decoder = nil
        // Now safe to stop and release renderer
        renderer?.stop()
        renderer = nil
        isActive = false
        fps = 0
        latencyMs = 0
        detectedH265 = false
        networkManager.disconnectAll()
    }

    private static var routeCount = 0
    private static var routeBytes = 0
    private func routeVideoData(_ data: Data) {
        // Don't decode video until PIN is verified
        if pendingPin != nil { return }
        IOSViewerSession.routeCount += 1
        IOSViewerSession.routeBytes += data.count
        let count = IOSViewerSession.routeCount
        if count <= 10 || count % 300 == 0 {
            let availMB = os_proc_available_memory() / 1_048_576
            CrashLog.write("routeVideoData #\(count): len=\(data.count) totalBytes=\(IOSViewerSession.routeBytes) h265=\(detectedH265) mem=\(availMB)MB")
        }
        guard data.count >= 5 else { return }

        if detectedH265 {
            if count <= 5 || count % 300 == 0 {
                NSLog("[video] h265 frame len=%d count=%d", data.count, count)
            }
            h265Decoder?.decode(annexBData: data)
            return
        }

        // Detect codec from first start code without copying entire frame
        data.withUnsafeBytes { rawBuf in
            guard let bytes = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let len = rawBuf.count
            var i = 0
            while i + 4 < len {
                if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                    let nalByte = bytes[i+4]
                    let h265Type = (nalByte >> 1) & 0x3F

                    if count <= 5 {
                        NSLog("[video] NAL detect: byte=0x%02x h265Type=%d count=%d len=%d",
                              nalByte, h265Type, count, data.count)
                    }

                    if h265Type >= 32 && h265Type <= 34 {
                        detectedH265 = true
                        NSLog("[video] Detected H.265! VPS/SPS/PPS found")
                        h265Decoder?.decode(annexBData: data)
                        return
                    }
                    break
                }
                i += 1
            }
            h264Decoder?.decode(annexBData: data)
        }
    }

    private func handleControlMessage(_ msg: Peariscope_ControlMessage) {
        switch msg.msg {
        case .codecNegotiation(let negotiation):
            let newH265 = negotiation.selectedCodec == .h265
            if newH265 != detectedH265 {
                CrashLog.write("CODEC SWITCH: h265=\(detectedH265) → \(newH265)")
                detectedH265 = newH265
                // Request keyframe for the new codec — old decoder's state is stale
                requestIDR()
            }
        case .frameTimestamp(let ts):
            _ = latencyTracker.measureFromTimestamp(ts.captureTimeMs)
        case .clipboard(let clipboard):
            networkManager.clipboardSharing.applyRemoteClipboard(clipboard.text)
        case .displayList(let list):
            availableDisplays = list.displays
            if let active = list.displays.first(where: { $0.isActive }) {
                activeDisplayId = active.displayID
            }
        case .peerChallenge(let challenge):
            CrashLog.write("PIN CHALLENGE received — showing PIN entry")
            pendingPin = "pending"
            pinEntryText = ""
            if !challenge.peerKey.isEmpty {
                let hexKey = challenge.peerKey.map { String(format: "%02x", $0) }.joined()
                hostFingerprint = PeerFingerprint.format(hexKey)
            }
        case .peerChallengeResponse(let response):
            CrashLog.write("PIN RESPONSE from host: accepted=\(response.accepted)")
            if response.accepted {
                pendingPin = nil
                hostFingerprint = nil
                requestIDR()
            }
        case .cursorPosition(let pos):
            self.remoteCursorX = pos.x
            self.remoteCursorY = pos.y
        default:
            break
        }
    }

    func submitPin() {
        CrashLog.write("submitPin(): sending PIN '\(pinEntryText)' to \(networkManager.connectedPeers.count) peers")
        var response = Peariscope_PeerChallengeResponse()
        response.pin = pinEntryText
        response.accepted = true
        var control = Peariscope_ControlMessage()
        control.peerChallengeResponse = response
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
        pendingPin = nil
    }

    func cancelPinChallenge() {
        var response = Peariscope_PeerChallengeResponse()
        response.pin = ""
        response.accepted = false
        var control = Peariscope_ControlMessage()
        control.peerChallengeResponse = response
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
        pendingPin = nil
        disconnect()
        onExitViewer?()
    }

    func switchDisplay(to displayId: UInt32) {
        var switchMsg = Peariscope_SwitchDisplay()
        switchMsg.displayID = displayId
        var control = Peariscope_ControlMessage()
        control.switchDisplay = switchMsg
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    func requestIDR() {
        var control = Peariscope_ControlMessage()
        control.requestIdr = Peariscope_RequestIdr()
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    func updateViewport() {
        guard textureWidth > 0, textureHeight > 0, let mtkView, let renderer else { return }
        let viewSize = mtkView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let texAR = Float(textureWidth) / Float(textureHeight)
        let viewAR = Float(viewSize.width) / Float(viewSize.height)

        var scaleX: Float
        var scaleY: Float

        if texAR > viewAR {
            scaleY = 1.0
            scaleX = viewAR / texAR
        } else {
            scaleX = 1.0
            scaleY = texAR / viewAR
        }

        // [2] Apply user zoom
        scaleX /= userZoom
        scaleY /= userZoom

        // Clamp scales to not exceed full texture
        scaleX = min(scaleX, 1.0)
        scaleY = min(scaleY, 1.0)

        // Center viewport on cursor + user pan offset
        let cx = cursorX + userPanOffset.x
        let cy = cursorY + userPanOffset.y
        let offsetX = min(max(cx - scaleX * 0.5, 0), 1.0 - scaleX)
        let offsetY = min(max(cy - scaleY * 0.5, 0), 1.0 - scaleY)

        renderer.setViewport(offset: SIMD2<Float>(offsetX, offsetY), scale: SIMD2<Float>(scaleX, scaleY))
    }

    func moveCursor(to normalizedX: Float, to normalizedY: Float) {
        cursorX = normalizedX
        cursorY = normalizedY
        updateViewport()
    }

    weak var keyboardTextField: UITextField?
    private var keyboardVisible = false

    func toggleKeyboard() {
        NSLog("[viewer] toggleKeyboard called, tf=%@, isFirstResponder=%@",
              keyboardTextField != nil ? "exists" : "nil",
              keyboardTextField?.isFirstResponder == true ? "yes" : "no")
        if let tf = keyboardTextField {
            if keyboardVisible {
                tf.resignFirstResponder()
                keyboardVisible = false
            } else {
                tf.becomeFirstResponder()
                keyboardVisible = true
            }
        }
    }

    func toggleMouseMode() {
        isTrackpadMode.toggle()
    }

    /// Type a string by sending individual key down/up events for each character,
    /// followed by an Enter key press.
    func typeString(_ text: String) {
        for char in text {
            if char == "\n" || char == "\r" {
                sendVirtualKey(keycode: 36) // Return
            } else if char == "\t" {
                sendVirtualKey(keycode: 48) // Tab
            } else {
                var keyEvent = Peariscope_KeyEvent()
                keyEvent.keycode = UInt32(char.unicodeScalars.first?.value ?? 0)
                keyEvent.pressed = true
                var down = Peariscope_InputEvent()
                down.key = keyEvent
                sendInput(down)

                keyEvent.pressed = false
                var up = Peariscope_InputEvent()
                up.key = keyEvent
                sendInput(up)
            }
        }
        // Send Enter after the text
        sendVirtualKey(keycode: 36)
    }

    func sendVirtualKey(keycode: UInt32) {
        var keyEvent = Peariscope_KeyEvent()
        keyEvent.keycode = keycode
        keyEvent.modifiers = 0x80000000
        keyEvent.pressed = true
        var down = Peariscope_InputEvent()
        down.key = keyEvent
        sendInput(down)

        keyEvent.pressed = false
        var up = Peariscope_InputEvent()
        up.key = keyEvent
        sendInput(up)
    }

    func sendInput(_ event: Peariscope_InputEvent) {
        guard let data = encodeInputEvent(event) else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendInputData(data, streamId: peer.streamId)
        }
    }
}
#endif
