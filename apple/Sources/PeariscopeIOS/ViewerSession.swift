#if os(iOS)
import SwiftUI
import MetalKit
import CoreMedia
import UIKit
import PeariscopeCore
import AVFoundation
import AVKit
import Combine

// MARK: - iOS Viewer Session

@MainActor
final class IOSViewerSession: ObservableObject {
    @Published var isActive = false
    @Published var fps: Double = 0
    @Published var latencyMs: Double = 0
    @Published var bandwidthBytesPerSec: Int64 = 0
    @Published var isTrackpadMode = true
    @Published var isReconnecting = false
    @Published var connectionLost = false  // true when all reconnect attempts failed
    @Published var hasReceivedFirstFrame = false
    @Published var availableDisplays: [Peariscope_DisplayInfo] = []
    @Published var activeDisplayId: UInt32 = 0
    @Published var pendingPin: String?
    @Published var pinEntryText: String = ""
    @Published var hostFingerprint: String?
    /// Live diagnostic lines shown on "Waiting for video..." overlay
    @Published var diagnosticLines: [String] = []
    /// Remote cursor position from host (normalized 0-1)
    /// NOT @Published — updated at high frequency, would cause excessive SwiftUI re-renders
    var remoteCursorX: Float = 0.5
    var remoteCursorY: Float = 0.5
    /// When true, ignore incoming CursorPosition from host (user is actively touching)
    var isTouching = false
    /// Timestamp of last touch end — suppress host cursor updates briefly after lift-off
    /// to prevent queued host events from moving the cursor
    var lastTouchEndTime: CFAbsoluteTime = 0

    /// Called when the viewer should exit back to the connect screen.
    /// ONLY called by explicit user action (disconnect button, PIN cancel).
    var onExitViewer: (() -> Void)?

    /// Tracks whether we've suspended the worklet due to memory pressure
    private var workletSuspendedForMemory = false

    private var h264Decoder: H264Decoder?
    private var h265Decoder: H265Decoder?
    private var audioPlayer: AudioPlayer?
    private(set) var renderer: MetalRenderer?
    let networkManager: NetworkManager
    private let latencyTracker = LatencyTracker()
    private var detectedH265 = false

    deinit {
        CrashLog.write("IOSViewerSession.deinit — session deallocated")
        NSLog("[viewer] IOSViewerSession.deinit — session deallocated")
    }

    private var frameCountInInterval = 0
    nonisolated(unsafe) private var bytesReceivedInInterval: Int64 = 0
    private let bytesLock = NSLock()
    private var idrRetryCount = 0
    private var fpsTimer: Timer?
    private var qualityReportTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryWarningObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var lastBridgeDiag: String = ""
    private var bridgeStaleCount = 0
    private var reconnectStateCancellable: AnyCancellable?

    // Jitter tracking: variance in inter-frame arrival times
    nonisolated(unsafe) private var lastFrameArrival: CFAbsoluteTime = 0
    nonisolated(unsafe) private var frameIntervals: [Double] = []
    private let jitterLock = NSLock()

    // MARK: - Picture-in-Picture
    private var pipController: AVPictureInPictureController?
    private(set) var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var cachedFormatDescription: CMFormatDescription?
    private var currentThermalState: ProcessInfo.ThermalState = .nominal
    private var lastFrameTime: Date = Date()
    private(set) var textureWidth: Int = 0
    private(set) var textureHeight: Int = 0
    var cursorX: Float = 0.5
    var cursorY: Float = 0.5
    weak var mtkView: MTKView?

    /// [6] Last connection code for auto-reconnect
    private var lastCode: String?

    /// User-applied zoom multiplier (1.0 = fit, >1.0 = zoomed in)
    var userZoom: Float = 1.0
    /// User pan offset (in normalized coords, applied on top of cursor-follow)
    var userPanOffset: SIMD2<Float> = .zero

    /// Thread-safe bandwidth byte counting — called from BareKit threads.
    nonisolated func addReceivedBytes(_ count: Int) {
        bytesLock.lock()
        bytesReceivedInInterval += Int64(count)
        bytesLock.unlock()
    }

    nonisolated func resetReceivedBytes() -> Int64 {
        bytesLock.lock()
        let bytes = bytesReceivedInInterval
        bytesReceivedInInterval = 0
        bytesLock.unlock()
        return bytes
    }

    /// Formatted bandwidth string for display.
    var bandwidthFormatted: String {
        let bytes = bandwidthBytesPerSec
        if bytes >= 1_000_000 {
            return String(format: "%.1fMB/s", Double(bytes) / 1_000_000.0)
        } else if bytes >= 1_000 {
            return "\(bytes / 1_000)KB/s"
        }
        return ""
    }

    /// Whether callbacks have been configured on networkManager.
    /// Prevents throwaway sessions (created by @StateObject during parent re-renders)
    /// from overwriting the real session's callbacks.
    private var callbacksConfigured = false

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        CrashLog.write("IOSViewerSession.init() — isConnected=\(networkManager.isConnected) peers=\(networkManager.connectedPeers.count)")
        // Don't set networkManager callbacks here! @StateObject creates throwaway
        // IOSViewerSession instances on every parent re-render. Those throwaways
        // would overwrite the real session's callbacks with dead weak refs.
        // Callbacks are set in configureCallbacks(), called from setup().
    }

    /// Set up networkManager callbacks. Called once from setup().
    /// Must NOT be called from init() — @StateObject creates throwaway sessions
    /// during parent view re-renders whose inits would corrupt these callbacks.
    private func configureCallbacks() {
        guard !callbacksConfigured else { return }
        callbacksConfigured = true
        NSLog("[viewer] configureCallbacks — setting networkManager callbacks")

        // PIN challenges that arrive before this point are buffered in
        // networkManager.pendingControlData and replayed when onControlData is set.
        networkManager.onControlData = { [weak self] data in
            NSLog("[viewer] onControlData fired: %d bytes", data.count)
            guard let msg = try? Peariscope_ControlMessage(serializedBytes: data) else {
                NSLog("[viewer] onControlData: failed to parse protobuf")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let msgType: String
                switch msg.msg {
                case .codecNegotiation: msgType = "codecNeg"
                case .peerChallenge: msgType = "pinChallenge"
                case .peerChallengeResponse: msgType = "pinResponse"
                case .displayList: msgType = "displayList"
                case .cursorPosition: msgType = "cursor"
                case .frameTimestamp: msgType = "timestamp"
                default: msgType = "other"
                }
                if msgType != "cursor" && msgType != "timestamp" {
                    self.addDiag("ctrl: \(msgType) (\(data.count)B)")
                }
                self.handleControlMessage(msg)
            }
        }

        networkManager.onPeerConnected = { [weak self] peer in
            DispatchQueue.main.async { [weak self] in
                self?.addDiag("PEER CONNECTED: sid=\(peer.streamId)")
            }
        }

        networkManager.onPeerDisconnected = { [weak self] peer in
            guard let self else { return }
            Task { @MainActor in
                // ReconnectionManager drives reconnect state via its published state.
                // Only fall back to local attemptReconnect if manager is idle
                // (e.g. user-initiated disconnect won't trigger manager).
                if self.networkManager.reconnectionManager.state == .idle {
                    self.attemptReconnect()
                }
            }
        }

        networkManager.onJSLog = { [weak self] msg in
            CrashLog.write("JS: \(msg)")
            self?.addDiag("JS: \(msg)")
        }
    }

    /// Add a diagnostic line visible on the "Waiting for video..." overlay
    private func addDiag(_ line: String) {
        let entry = "\(Self.diagDateFmt.string(from: Date())) \(line)"
        if Thread.isMainThread {
            diagnosticLines.append(entry)
            if diagnosticLines.count > 200 { diagnosticLines.removeFirst() }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.diagnosticLines.append(entry)
                if (self?.diagnosticLines.count ?? 0) > 200 { self?.diagnosticLines.removeFirst() }
            }
        }
    }
    private static let diagDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func setup(mtkView: MTKView) {
        NSLog("[viewer] setup() called, creating decoders and renderer")
        // Set up networkManager callbacks ONCE. Must happen here (not init)
        // because @StateObject creates throwaway sessions during re-renders.
        configureCallbacks()

        // Subscribe to reconnection manager state changes
        reconnectStateCancellable = networkManager.reconnectionManager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .reconnecting:
                    self.isReconnecting = true
                    self.connectionLost = false
                case .failed:
                    self.isReconnecting = false
                    self.connectionLost = true
                case .idle:
                    // If we were reconnecting and now idle, reconnect succeeded
                    if self.isReconnecting {
                        self.isReconnecting = false
                        self.connectionLost = false
                        self.requestIDR()
                    }
                }
            }

        // Reset static counters so FIRST VIDEO DATA logs each time
        IOSViewerSession.routeCount = 0
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
        let sbLayer = sampleBufferDisplayLayer
        let onDecoded: (CVPixelBuffer, CMTime) -> Void = { [weak self] pixelBuffer, _ in
            // renderer.display() is thread-safe (NSLock), safe from VT thread
            metalRenderer?.display(pixelBuffer: pixelBuffer)
            // Feed PiP sample buffer layer (also thread-safe)
            self?.enqueuePiPFrame(pixelBuffer)
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
                self.recordFrameArrival()
            }
        }

        h264.onDecodedFrame = onDecoded
        h265.onDecodedFrame = onDecoded

        h265.onCodecFallbackNeeded = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.requestCodecFallback()
            }
        }

        h264Decoder = h264
        h265Decoder = h265

        addDiag("setup: decoders+renderer created")

        // Direct video callback on the bridge — bypasses NetworkManager's @MainActor
        // isolation entirely. In Swift 6, NetworkManager.onVideoData goes through actor
        // hopping which silently drops/delays video data. This callback fires directly
        // on BareKit's IPC thread. Decoders are thread-safe (own serial queues).
        //
        // IMPORTANT: This closure must be minimal — no mutable captured vars, no file I/O,
        // no complex diagnostics. It runs on BareKit's thread pool.
        networkManager.setDirectVideoCallback { [weak self] data in
            guard data.count >= 5 else { return }
            self?.addReceivedBytes(data.count)
            IOSViewerSession.routeCount += 1
            // Feed both decoders — each ignores NALs it doesn't understand.
            // This avoids codec detection logic on BareKit's thread.
            h264.decode(annexBData: data)
            h265.decode(annexBData: data)
        }

        // Set up audio playback
        // NOTE: AVAudioSession is configured once at app launch (PeariscopeAppDelegate).
        // AudioPlayer.start() no longer calls setCategory/setActive, so it's safe
        // to call synchronously here without deadlocking the main thread.
        let player = AudioPlayer(sampleRate: 48000, channels: 2)
        do {
            try player.start()
            audioPlayer = player
            NSLog("[viewer] Audio player started")
        } catch {
            NSLog("[viewer] Audio player failed: %@", error.localizedDescription)
        }
        networkManager.onAudioData = { [weak player, weak self] data in
            self?.addReceivedBytes(data.count)
            player?.decodeAndPlay(aacData: data)
        }

        isActive = true
        addDiag("peers: \(networkManager.connectedPeers.count) connected=\(networkManager.isConnected)")
        requestIDR()
        addDiag("requestIDR sent")
        CrashLog.write("setup() complete")

        // Retry IDR request after a short delay — the initial requestIDR() may fire
        // before the peer connection is fully established, especially on first connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isActive, !self.hasReceivedFirstFrame else { return }
            self.addDiag("retry IDR: peers=\(self.networkManager.connectedPeers.count) video=#\(IOSViewerSession.routeCount)")
                self.requestIDR()
        }
        // Additional retries at 3s and 5s
        for delay in [3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive, !self.hasReceivedFirstFrame else { return }
                self.addDiag("retry IDR @\(Int(delay))s: peers=\(self.networkManager.connectedPeers.count) video=#\(IOSViewerSession.routeCount)")
                self.requestIDR()
            }
        }

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let frames = self.frameCountInInterval
                self.fps = Double(frames)
                self.frameCountInInterval = 0
                self.latencyMs = self.latencyTracker.averageLatencyMs
                self.bandwidthBytesPerSec = self.resetReceivedBytes()
                // Heartbeat to persistent crash log — if the app dies,
                // the last heartbeat tells us exactly when and memory state
                let availMB = os_proc_available_memory() / 1_048_576
                CrashLog.write("heartbeat: fps=\(frames) mem=\(availMB)MB tex=\(self.textureWidth)x\(self.textureHeight)")
                self.drainDiagQueue()
                if !self.hasReceivedFirstFrame {
                    self.addDiag("hb: fps=\(frames) video=#\(IOSViewerSession.routeCount) peers=\(self.networkManager.connectedPeers.count) mem=\(availMB)MB h264=\(self.h264Decoder?.hasSession ?? false)")
                    self.addDiag("bridge: \(self.networkManager.bridgeDiagnosticSummary())")
                }
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
                // Stale worklet detection — if IPC counters haven't changed
                // for 30+ seconds while active, the worklet is stuck in a CPU spin loop.
                // Restart it to recover.
                let bridgeDiag = self.networkManager.bridgeDiagnosticSummary()
                if bridgeDiag == self.lastBridgeDiag && self.networkManager.isWorkletAlive {
                    self.bridgeStaleCount += 1
                    if self.bridgeStaleCount >= 30 {
                        CrashLog.write("STALE WORKLET: IPC counters unchanged for \(self.bridgeStaleCount)s — restarting")
                        self.bridgeStaleCount = 0
                        self.restartStaleWorklet()
                    }
                } else {
                    self.bridgeStaleCount = 0
                }
                self.lastBridgeDiag = bridgeDiag

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

    /// Restart a worklet that's stuck in a CPU spin loop.
    /// Terminates and restarts without exiting the viewer.
    private func restartStaleWorklet() {
        CrashLog.write("RESTARTING STALE WORKLET")
        networkManager.shutdown()
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard self.isActive else { return }
            if !self.networkManager.isWorkletAlive {
                try? await self.networkManager.startRuntime()
            }
            self.attemptReconnect()
        }
    }

    // [6] Handle memory pressure — terminate worklet but stay in viewer, reconnect
    private func handleMemoryPressure() {
        guard !workletSuspendedForMemory else { return }
        workletSuspendedForMemory = true
        // Kill the worklet to free V8/libuv memory, but DON'T exit the viewer.
        // Clear video/control callbacks to stop data flow, but keep onPeerDisconnected
        // so we detect when the connection is fully dead.
        networkManager.setDirectVideoCallback(nil)
        networkManager.onVideoData = nil
        networkManager.onAudioData = nil
        // Keep onControlData alive — PIN challenges need to work after reconnect
        h264Decoder?.stop()
        h264Decoder = nil
        h265Decoder?.stop()
        h265Decoder = nil
        audioPlayer?.stop()
        audioPlayer = nil
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

    /// Retry connection after all automatic reconnect attempts failed.
    /// Called from the "Retry" button in ViewerView.
    func retryConnection() {
        guard let code = lastCode else { return }
        connectionLost = false
        isReconnecting = true
        Task {
            do {
                try await networkManager.connectFromQR(code)
            } catch {
                NSLog("[viewer] retryConnection failed: %@", error.localizedDescription)
                isReconnecting = false
                connectionLost = true
            }
        }
    }

    // [14] Send quality report to host for adaptive bitrate
    /// Record a frame arrival for jitter calculation. Called from decode callback.
    private func recordFrameArrival() {
        let now = CFAbsoluteTimeGetCurrent()
        jitterLock.lock()
        if lastFrameArrival > 0 {
            let interval = (now - lastFrameArrival) * 1000  // ms
            frameIntervals.append(interval)
            if frameIntervals.count > 60 { frameIntervals.removeFirst() }
        }
        lastFrameArrival = now
        jitterLock.unlock()
    }

    /// Compute inter-frame arrival jitter (standard deviation of intervals)
    private func computeJitterMs() -> Double {
        jitterLock.lock()
        let intervals = frameIntervals
        jitterLock.unlock()
        guard intervals.count > 1 else { return 0 }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        return sqrt(variance)
    }

    private func sendQualityReport() {
        var report = Peariscope_QualityReport()
        report.fps = UInt32(fps)
        report.rttMs = UInt32(latencyMs)
        report.bitrateKbps = 0
        // Send native screen resolution so host can downscale capture
        let screen = UIScreen.main.nativeBounds
        report.screenWidth = UInt32(screen.width)
        report.screenHeight = UInt32(screen.height)
        // Throughput: actual bytes received converted to kbps
        report.receivedKbps = UInt32(bandwidthBytesPerSec * 8 / 1000)
        report.jitterMs = Float(computeJitterMs())

        var control = Peariscope_ControlMessage()
        control.qualityReport = report

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    // MARK: - Picture-in-Picture

    /// Set up PiP with an AVSampleBufferDisplayLayer. Call from the UIView that hosts the layer.
    func setupPiP(displayLayer: AVSampleBufferDisplayLayer) {
        sampleBufferDisplayLayer = displayLayer

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            NSLog("[pip] PiP not supported on this device")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: PiPPlaybackDelegate.shared
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // Hide playback controls — this is a live stream, not playable content
        controller.setValue(1, forKey: "controlsStyle")
        pipController = controller
        NSLog("[pip] PiP controller created")
    }

    /// Enqueue a decoded pixel buffer to the PiP sample buffer display layer
    private func enqueuePiPFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let layer = sampleBufferDisplayLayer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Cache format description — only recreate when dimensions change
        if cachedFormatDescription == nil ||
            CMVideoFormatDescriptionGetDimensions(cachedFormatDescription!).width != Int32(width) ||
            CMVideoFormatDescriptionGetDimensions(cachedFormatDescription!).height != Int32(height) {
            var formatDesc: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            if status == noErr {
                cachedFormatDescription = formatDesc
            }
        }

        guard let formatDesc = cachedFormatDescription else { return }

        // Use host time for presentation — keeps PiP in sync
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        if status == noErr, let sb = sampleBuffer {
            layer.enqueue(sb)
        }
    }

    func disconnect() {
        isReconnecting = false
        connectionLost = false
        reconnectStateCancellable?.cancel()
        reconnectStateCancellable = nil
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
        networkManager.setDirectVideoCallback(nil)
        networkManager.onVideoData = nil
        networkManager.onAudioData = nil
        networkManager.onControlData = nil
        networkManager.onPeerDisconnected = nil
        // Stop decoders first — this waits for pending VT frames, ensuring
        // no more onDecodedFrame callbacks will fire after this returns
        h264Decoder?.stop()
        h264Decoder = nil
        h265Decoder?.stop()
        h265Decoder = nil
        audioPlayer?.stop()
        audioPlayer = nil
        // Stop PiP
        pipController?.stopPictureInPicture()
        pipController = nil
        sampleBufferDisplayLayer = nil
        cachedFormatDescription = nil
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

    // Thread-safe diagnostic queue — allows background threads to post
    // diagnostics without needing a weak self reference to @MainActor session.
    // The heartbeat drains this into diagnosticLines.
    private static let diagQueueLock = NSLock()
    private static var diagQueue: [String] = []
    static func queueDiag(_ msg: String) {
        let entry = "\(diagDateFmt.string(from: Date())) \(msg)"
        diagQueueLock.lock()
        diagQueue.append(entry)
        diagQueueLock.unlock()
    }
    private func drainDiagQueue() {
        Self.diagQueueLock.lock()
        let msgs = Self.diagQueue
        Self.diagQueue.removeAll()
        Self.diagQueueLock.unlock()
        for msg in msgs {
            diagnosticLines.append(msg)
        }
        if diagnosticLines.count > 200 {
            diagnosticLines.removeFirst(diagnosticLines.count - 200)
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
            if !clipboard.imagePng.isEmpty {
                networkManager.clipboardSharing.applyRemoteImage(clipboard.imagePng)
            } else {
                networkManager.clipboardSharing.applyRemoteClipboard(clipboard.text)
            }
        case .displayList(let list):
            availableDisplays = list.displays
            if let active = list.displays.first(where: { $0.isActive }) {
                activeDisplayId = active.displayID
            }
        case .peerChallenge(let challenge):
            NSLog("[viewer] PIN CHALLENGE received — showing PIN entry, pendingPin will be set to 'pending'")
            CrashLog.write("PIN CHALLENGE received — showing PIN entry")
            pendingPin = "pending"
            pinEntryText = ""
            if !challenge.peerKey.isEmpty {
                let hexKey = challenge.peerKey.map { String(format: "%02x", $0) }.joined()
                hostFingerprint = PeerFingerprint.format(hexKey)
            }
        case .peerChallengeResponse(let response):
            if response.accepted {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                pendingPin = nil
                hostFingerprint = nil
                IOSViewerSession.routeCount = 0
                requestIDR()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        case .ping(let ping):
            // Echo ping back as pong for host RTT measurement
            var pong = Peariscope_Pong()
            pong.timestampMs = ping.timestampMs
            var control = Peariscope_ControlMessage()
            control.pong = pong
            if let data = try? control.serializedData() {
                for peer in networkManager.connectedPeers {
                    try? networkManager.sendControlData(data, streamId: peer.streamId)
                }
            }
        case .pong:
            break  // Viewer doesn't use pongs
        case .cursorPosition(let pos):
            // Suppress host cursor updates while user is touching or briefly after lift-off,
            // otherwise queued host events move the cursor after the user lifts their finger
            let elapsed = CFAbsoluteTimeGetCurrent() - lastTouchEndTime
            if !isTouching && elapsed > 0.5 {
                self.remoteCursorX = pos.x
                self.remoteCursorY = pos.y
                // Sync local cursor tracking so trackpad-mode clicks
                // don't jump to a stale position
                self.cursorX = pos.x
                self.cursorY = pos.y
            }
        default:
            break
        }
    }

    func submitPin() {
        var response = Peariscope_PeerChallengeResponse()
        response.pin = pinEntryText
        response.accepted = true
        var control = Peariscope_ControlMessage()
        control.peerChallengeResponse = response
        guard let data = try? control.serializedData() else {
            NSLog("[pin] submitPin: failed to serialize response")
            return
        }
        let peers = networkManager.connectedPeers
        NSLog("[pin] submitPin: peers=\(peers.count) pinLen=\(pinEntryText.count) dataLen=\(data.count)")
        for peer in peers {
            NSLog("[pin] sending to peer sid=\(peer.streamId) id=\(peer.id.prefix(16))")
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
        if peers.isEmpty {
            CrashLog.write("submitPin: no peers to send to")
            pendingPin = nil  // No peers — clear overlay so user isn't stuck
        }
        // Don't clear pendingPin here — wait for host's PeerChallengeResponse(accepted: true)
        // to confirm the PIN was correct. The overlay stays until confirmation arrives.
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

    /// Request the host to switch from H.265 to H.264 due to decode failures
    private func requestCodecFallback() {
        CrashLog.write("CODEC FALLBACK: H.265 decode failing, requesting H.264")
        var negotiation = Peariscope_CodecNegotiation()
        negotiation.supportedCodecs = [.h264]
        negotiation.selectedCodec = .h264
        var control = Peariscope_ControlMessage()
        control.codecNegotiation = negotiation
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
        detectedH265 = false
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
                sendVirtualKey(keycode: VK.return.rawValue)
            } else if char == "\t" {
                sendVirtualKey(keycode: VK.tab.rawValue)
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
        sendVirtualKey(keycode: VK.return.rawValue)
    }

    func sendVirtualKey(keycode: UInt32, modifiers: UInt32 = 0) {
        var keyEvent = Peariscope_KeyEvent()
        keyEvent.keycode = keycode
        // 0x80000000 marker tells host this is a raw CGKeyCode, not Unicode
        keyEvent.modifiers = 0x80000000 | modifiers
        keyEvent.pressed = true
        var down = Peariscope_InputEvent()
        down.key = keyEvent
        sendInput(down)

        keyEvent.pressed = false
        var up = Peariscope_InputEvent()
        up.key = keyEvent
        sendInput(up)
    }

    /// Send a key combo like Cmd+C: modifier keys press, key press, key release, modifier keys release
    func sendKeyCombo(keycode: UInt32, modifiers: InputModifiers) {
        sendVirtualKey(keycode: keycode, modifiers: modifiers.rawValue)
    }

    func sendInput(_ event: Peariscope_InputEvent) {
        guard let data = encodeInputEvent(event) else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendInputData(data, streamId: peer.streamId)
        }
    }
}

// MARK: - PiP Playback Delegate

/// Singleton delegate for AVPictureInPictureController — returns live stream metadata.
/// Must be a class (not struct) conforming to NSObjectProtocol.
final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    nonisolated(unsafe) static let shared = PiPPlaybackDelegate()
    private override init() { super.init() }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        // Live stream — always playing, nothing to toggle
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Return infinite duration to indicate live content
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        return false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // Could notify host to adjust resolution for PiP window size
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        completion() // No seeking in live content
    }
}
#endif
