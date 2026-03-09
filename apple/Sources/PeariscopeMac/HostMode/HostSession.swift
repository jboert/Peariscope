import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import PeariscopeCore
import os.log

/// Orchestrates the host-side pipeline: capture -> encode -> network, network -> input injection
/// Supports adaptive quality and H.264/H.265 codec switching.
@MainActor
public final class HostSession: ObservableObject {
    @Published public var isActive = false
    @Published public var fps: Double = 0
    @Published public var bitrate: Int = 8_000_000
    @Published public var selectedDisplay: SCDisplay?
    @Published public var availableDisplays: [SCDisplay] = []
    @Published public var hasAccessibilityPermission = false
    @Published public var useH265 = false
    @Published public var adaptiveQualityEnabled = true
    @Published public var pendingPeerPin: String?
    @Published public var pendingPeerKey: Data?
    @Published public var pendingPeerFingerprint: String?
    /// Peers awaiting PIN verification — no video/input sent until approved
    private var pendingPeerIds: Set<String> = []
    // PIN brute-force protection
    private var failedPinAttempts: [String: Int] = [:]
    private var peerLockoutUntil: [String: Date] = [:]
    private let maxPinAttempts = 5
    private let lockoutDuration: TimeInterval = 300
    @Published public var requirePinVerification: Bool {
        didSet { UserDefaults.standard.set(requirePinVerification, forKey: "peariscope.requirePin") }
    }
    @Published public var pinCode: String {
        didSet { UserDefaults.standard.set(pinCode, forKey: "peariscope.pinCode") }
    }
    @Published public var maxViewers: Int {
        didSet { UserDefaults.standard.set(maxViewers, forKey: "peariscope.maxViewers") }
    }
    @Published public var clipboardEnabled = false {
        didSet {
            if clipboardEnabled {
                networkManager.enableClipboardSharing()
            } else {
                networkManager.disableClipboardSharing()
            }
        }
    }
    public var adaptiveResolutionEnabled: Bool {
        didSet { UserDefaults.standard.set(adaptiveResolutionEnabled, forKey: "peariscope.adaptiveResolution") }
    }

    private var capture: ScreenCapture?
    private var h264Encoder: H264Encoder?
    private var h265Encoder: H265Encoder?
    private var inputInjector: InputInjector?
    private var adaptiveQuality: AdaptiveQuality?
    private let networkManager: NetworkManager
    /// True when screen capture + encoders are running (peers are connected)
    private var isCaptureRunning = false

    private var frameCountInInterval = 0
    private var frameId: UInt32 = 0
    private var fpsTimer: Timer?
    private var cursorTimer: Timer?
    private var lastCursorX: Float = -1
    private var lastCursorY: Float = -1

    /// Per-peer screen resolution (peer id -> (width, height))
    private var peerResolutions: [String: (width: Int, height: Int)] = [:]
    /// Current capture resolution (may differ from display native if downscaled)
    private var currentCaptureWidth: Int = 0
    private var currentCaptureHeight: Int = 0

    // Rate limiting for input events
    private var inputEventCount = 0
    private var inputRateLimitTimer: Timer?
    private static let maxInputEventsPerSecond = 500
    // Rate limiting for control messages
    private var controlMsgCount = 0
    private var controlRateLimitTimer: Timer?
    private static let maxControlMsgsPerSecond = 120

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        self.hasAccessibilityPermission = InputInjector.hasAccessibilityPermission
        self.useH265 = H265Encoder.isSupported
        self.requirePinVerification = UserDefaults.standard.object(forKey: "peariscope.requirePin") as? Bool ?? true
        self.pinCode = UserDefaults.standard.string(forKey: "peariscope.pinCode") ?? ""
        let savedMaxViewers = UserDefaults.standard.integer(forKey: "peariscope.maxViewers")
        self.maxViewers = savedMaxViewers > 0 ? savedMaxViewers : 5
        // Default to enabled; user can disable if it causes issues
        self.adaptiveResolutionEnabled = UserDefaults.standard.object(forKey: "peariscope.adaptiveResolution") as? Bool ?? true
    }

    public func refreshDisplays() async throws {
        availableDisplays = try await ScreenCapture.availableDisplays()
        if selectedDisplay == nil {
            selectedDisplay = availableDisplays.first
        }
    }

    public func start() async throws {
        HostSession.log("[host] start() called, selectedDisplay=\(selectedDisplay != nil), isActive=\(isActive)")
        if selectedDisplay == nil {
            try await refreshDisplays()
        }
        guard selectedDisplay != nil else {
            HostSession.log("[host] start() FAILED: no display selected")
            throw HostSessionError.noDisplaySelected
        }

        // Set up input injector
        if let display = selectedDisplay {
            inputInjector = InputInjector(displayWidth: display.width, displayHeight: display.height)
        }

        networkManager.onInputData = { [weak self] data in
            guard let self, self.pendingPeerIds.isEmpty else { return }
            guard let event = decodeInputEvent(data) else { return }
            self.inputEventCount += 1
            guard self.inputEventCount <= Self.maxInputEventsPerSecond else { return }
            self.inputInjector?.inject(event)
        }

        // Reset input rate counter every second
        inputRateLimitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.inputEventCount = 0
            self?.controlMsgCount = 0
        }

        // Handle control messages (IDR requests, quality reports)
        networkManager.onControlData = { [weak self] data in
            guard let self else { return }
            self.controlMsgCount += 1
            guard self.controlMsgCount <= Self.maxControlMsgsPerSecond else { return }
            if let controlMsg = try? Peariscope_ControlMessage(serializedBytes: data) {
                self.handleControlMessage(controlMsg)
            }
        }

        isActive = true

        // FPS counter + adaptive quality reporting
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fps = Double(self.frameCountInInterval)
                self.frameCountInInterval = 0
                // Periodic keyframe every 5 seconds for viewer recovery
                if self.isCaptureRunning && self.frameId > 0 && self.frameId % (60 * 5) < 60 {
                    self.forceKeyframe()
                }
            }
        }

        // Called from MainActor context (NetworkManager's task).
        // Do NOT wrap in another Task — that creates a race where the peer
        // appears in connectedPeers but not yet in pendingPeerIds, allowing
        // video frames to leak to unverified peers.
        networkManager.onPeerConnected = { [weak self] peer in
            guard let self else { return }

            // Enforce max viewers
            if self.networkManager.connectedPeers.count > self.maxViewers {
                HostSession.log("[host] Max viewers (\(self.maxViewers)) reached, rejecting peer")
                Task { @MainActor in
                    try? await self.networkManager.disconnect(peerKey: Data(hex: peer.id))
                }
                return
            }

            let fingerprint = PeerFingerprint.format(peer.id)
            HostSession.log("[host] Peer connected: key=\(peer.id.prefix(16)) fingerprint=\(fingerprint) time=\(ISO8601DateFormatter().string(from: Date()))")

            if self.requirePinVerification && !self.pinCode.isEmpty {
                // Block this peer from receiving video until PIN verified
                self.pendingPeerIds.insert(peer.id)
                self.pendingPeerPin = self.pinCode
                self.pendingPeerKey = Data(hex: peer.id)
                self.pendingPeerFingerprint = fingerprint

                var challenge = Peariscope_PeerChallenge()
                challenge.pin = self.pinCode
                challenge.peerKey = Data(hex: peer.id)
                var control = Peariscope_ControlMessage()
                control.peerChallenge = challenge
                if let data = try? control.serializedData() {
                    try? self.networkManager.sendControlData(data, streamId: peer.streamId)
                }
                HostSession.log("[host] Sent PIN challenge to peer: \(fingerprint), blocking video until verified")
                return
            }

            self.startStreamingToPeer(peer)
        }

        networkManager.onPeerDisconnected = { [weak self] peer in
            guard let self else { return }
            let disconnectFingerprint = PeerFingerprint.format(peer.id)
            HostSession.log("[host] Peer disconnected: \(disconnectFingerprint)")
            // Clear pending PIN challenge if the disconnecting peer was the one being challenged
            if self.pendingPeerIds.contains(peer.id) {
                self.pendingPeerIds.remove(peer.id)
                if self.pendingPeerKey == Data(hex: peer.id) {
                    self.pendingPeerPin = nil
                    self.pendingPeerKey = nil
                    self.pendingPeerFingerprint = nil
                    HostSession.log("[host] Pending peer disconnected, clearing PIN challenge: \(disconnectFingerprint)")
                }
            }
            // Clean up peer resolution tracking
            self.peerResolutions.removeValue(forKey: peer.id)
            // Stop capture when last peer disconnects
            let approvedPeers = self.networkManager.connectedPeers.filter { !self.pendingPeerIds.contains($0.id) }
            if approvedPeers.isEmpty && self.isCaptureRunning {
                HostSession.log("[host] Last peer disconnected, stopping capture")
                Task { @MainActor in
                    await self.stopCapture()
                }
            } else if self.isCaptureRunning {
                // Remaining peers may have different resolution needs
                Task { @MainActor in
                    await self.updateCaptureResolution()
                }
            }
        }

        try await networkManager.startHosting()
        hasAccessibilityPermission = InputInjector.hasAccessibilityPermission
    }

    /// Start screen capture and encoders — called when first peer connects
    private func startCapture() async {
        guard !isCaptureRunning, let display = selectedDisplay else { return }
        let width = display.width
        let height = display.height
        HostSession.log("[host] Starting capture: \(width)x\(height)")

        // Set up adaptive quality
        let aq = AdaptiveQuality(preferH265: useH265)
        aq.onSettingsChanged = { [weak self] settings in
            Task { @MainActor in
                self?.applyQualitySettings(settings)
            }
        }
        adaptiveQuality = aq

        // Create encoder based on codec preference
        if useH265 && H265Encoder.isSupported {
            let enc = H265Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, isKeyframe in
                if isKeyframe {
                    HostSession.log("[host-enc] H265 keyframe len=\(data.count) peers=\(self?.networkManager.connectedPeers.count ?? 0)")
                }
                self?.sendVideoToAllPeers(data)
            }
            try? enc.start(fps: 60)
            h265Encoder = enc
            HostSession.log("[host] Using H.265 encoder")
        } else {
            let enc = H264Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, isKeyframe in
                if isKeyframe {
                    HostSession.log("[host-enc] H264 keyframe len=\(data.count) peers=\(self?.networkManager.connectedPeers.count ?? 0)")
                }
                self?.sendVideoToAllPeers(data)
            }
            try? enc.start(fps: 60)
            h264Encoder = enc
            HostSession.log("[host] Using H.264 encoder")
        }

        // Create and start screen capture
        let cap = ScreenCapture()
        cap.onFrame = { [weak self] pixelBuffer, pts in
            guard let self else { return }
            self.h264Encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.h265Encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.frameCountInInterval += 1
            self.frameId += 1
            if self.frameId % 30 == 0 {
                self.sendFrameTimestamp()
            }
        }
        cap.onError = { [weak self] error in
            HostSession.log("[host] Capture error: \(error)")
            guard let self else { return }
            Task { @MainActor in
                await self.restartCapture()
            }
        }

        do {
            try await cap.start(display: display, fps: 60)
            capture = cap
            isCaptureRunning = true
            currentCaptureWidth = width
            currentCaptureHeight = height
            startCursorTracking(display: display)
            HostSession.log("[host] Capture started successfully")
        } catch {
            HostSession.log("[host] Failed to start capture: \(error)")
        }
    }

    /// Stop screen capture and encoders — called when last peer disconnects
    private func stopCapture() async {
        guard isCaptureRunning else { return }
        HostSession.log("[host] Stopping capture (no peers)")

        cursorTimer?.invalidate()
        cursorTimer = nil

        try? await capture?.stop()
        capture = nil

        h264Encoder?.stop()
        h264Encoder = nil
        h265Encoder?.stop()
        h265Encoder = nil

        adaptiveQuality = nil
        isCaptureRunning = false
        currentCaptureWidth = 0
        currentCaptureHeight = 0
        peerResolutions.removeAll()
        fps = 0
        frameCountInInterval = 0
    }

    /// Compute optimal capture resolution based on connected viewers and update pipeline if needed
    private func updateCaptureResolution() async {
        guard isCaptureRunning, let display = selectedDisplay else { return }
        guard adaptiveResolutionEnabled else { return }

        let displayW = display.width
        let displayH = display.height

        // Find the largest viewer screen (we need to serve all viewers, so use max)
        var maxViewerW = 0
        var maxViewerH = 0
        for (_, res) in peerResolutions {
            // Use landscape orientation (max dimension as width) for comparison
            let w = max(res.width, res.height)
            let h = min(res.width, res.height)
            maxViewerW = max(maxViewerW, w)
            maxViewerH = max(maxViewerH, h)
        }

        // No resolution info yet — keep native
        guard maxViewerW > 0 && maxViewerH > 0 else { return }

        // Don't upscale — clamp to display native
        let targetW = min(displayW, maxViewerW)
        // Maintain display aspect ratio
        let targetH = min(displayH, targetW * displayH / displayW)

        // Only change if meaningfully different (>10% change) to avoid thrashing
        let widthRatio = Double(targetW) / Double(currentCaptureWidth)
        if currentCaptureWidth > 0 && widthRatio > 0.9 && widthRatio < 1.1 {
            return
        }

        // Don't downscale below 50% of native — diminishing returns
        guard targetW >= displayW / 2 else {
            if currentCaptureWidth != displayW / 2 {
                let halfW = displayW / 2
                let halfH = displayH / 2
                HostSession.log("[host] Adaptive resolution: clamping to 50% native: \(halfW)x\(halfH)")
                await applyResolutionChange(width: halfW, height: halfH)
            }
            return
        }

        // Skip if already at target
        if targetW == currentCaptureWidth && targetH == currentCaptureHeight { return }

        HostSession.log("[host] Adaptive resolution: \(currentCaptureWidth)x\(currentCaptureHeight) -> \(targetW)x\(targetH) (viewer max: \(maxViewerW)x\(maxViewerH), display: \(displayW)x\(displayH))")
        await applyResolutionChange(width: targetW, height: targetH)
    }

    /// Apply a resolution change: update capture config + recreate encoders
    private func applyResolutionChange(width: Int, height: Int) async {
        guard isCaptureRunning else { return }

        // Update SCStream capture resolution
        do {
            try await capture?.updateResolution(width: width, height: height)
        } catch {
            HostSession.log("[host] Failed to update capture resolution: \(error)")
            return
        }

        // Recreate encoders with new dimensions
        h264Encoder?.stop()
        h264Encoder = nil
        h265Encoder?.stop()
        h265Encoder = nil

        if useH265 && H265Encoder.isSupported {
            let enc = H265Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, isKeyframe in
                self?.sendVideoToAllPeers(data)
            }
            try? enc.start(fps: 60)
            h265Encoder = enc
        } else {
            let enc = H264Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, isKeyframe in
                self?.sendVideoToAllPeers(data)
            }
            try? enc.start(fps: 60)
            h264Encoder = enc
        }

        currentCaptureWidth = width
        currentCaptureHeight = height

        // Force keyframe after resolution change so viewers get a clean frame
        forceKeyframe()
        sendCodecNegotiation()
    }

    /// Poll mouse position and send to viewers — only sends when position changes
    private func startCursorTracking(display: SCDisplay) {
        let screenWidth = CGFloat(display.width)
        let screenHeight = CGFloat(display.height)
        // Poll at ~60Hz — matches display refresh for smooth client-side cursor
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            // NSEvent.mouseLocation is in screen coords with origin at bottom-left
            // Find the display's screen frame to normalize
            guard let screen = NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == display.displayID }) else { return }
            let frame = screen.frame
            let nx = Float((mouseLocation.x - frame.origin.x) / frame.width)
            // Flip Y: NSEvent has origin at bottom-left, we need top-left
            let ny = Float(1.0 - (mouseLocation.y - frame.origin.y) / frame.height)
            // Only send if position changed meaningfully (> ~0.5px at 1920 width)
            let dx = abs(nx - self.lastCursorX)
            let dy = abs(ny - self.lastCursorY)
            guard dx > 0.0003 || dy > 0.0003 else { return }
            self.lastCursorX = nx
            self.lastCursorY = ny

            var cursor = Peariscope_CursorPosition()
            cursor.x = nx
            cursor.y = ny
            var control = Peariscope_ControlMessage()
            control.cursorPosition = cursor
            guard let data = try? control.serializedData() else { return }
            for peer in self.networkManager.connectedPeers {
                guard !self.pendingPeerIds.contains(peer.id) else { continue }
                try? self.networkManager.sendControlData(data, streamId: peer.streamId)
            }
        }
    }

    public func stop() async throws {
        HostSession.log("[host] stop() called, isActive=\(isActive)")
        fpsTimer?.invalidate()
        fpsTimer = nil
        inputRateLimitTimer?.invalidate()
        inputRateLimitTimer = nil

        await stopCapture()

        inputInjector = nil
        networkManager.onInputData = nil
        networkManager.onControlData = nil
        networkManager.onPeerConnected = nil
        networkManager.onPeerDisconnected = nil
        pendingPeerIds.removeAll()
        pendingPeerPin = nil
        pendingPeerKey = nil
        pendingPeerFingerprint = nil
        peerResolutions.removeAll()

        try await networkManager.stopHosting()
        isActive = false
    }

    /// Begin sending video/codec/display info to a verified peer
    private func startStreamingToPeer(_ peer: NetworkManager.PeerState) {
        HostSession.log("[host] startStreamingToPeer: id=\(peer.id.prefix(16)) streamId=\(peer.streamId) pending=\(pendingPeerIds) connectedPeers=\(networkManager.connectedPeers.count)")
        Task { @MainActor in
            // Start capture on first approved peer
            if !self.isCaptureRunning {
                await self.startCapture()
            }
            self.forceKeyframe()
            self.sendCodecNegotiation()
            self.sendDisplayList()
            HostSession.log("[host] Sent codec+display to peer, forcing keyframes over next 2s")
            for delay in [0.5, 1.0, 2.0] {
                try? await Task.sleep(for: .seconds(delay))
                self.forceKeyframe()
            }
        }
    }

    /// Host approves or rejects the pending peer connection
    public func respondToPeer(accepted: Bool) {
        guard let pin = pendingPeerPin, let peerKey = pendingPeerKey else {
            HostSession.log("[host] respondToPeer(\(accepted)): SKIPPED — pendingPeerPin=\(pendingPeerPin != nil) pendingPeerKey=\(pendingPeerKey != nil)")
            return
        }
        let peerIdHex = peerKey.map { String(format: "%02x", $0) }.joined()
        HostSession.log("[host] Peer \(accepted ? "approved" : "rejected") with PIN \(pin), peerIdHex=\(peerIdHex.prefix(16))")
        pendingPeerPin = nil
        pendingPeerKey = nil
        pendingPeerFingerprint = nil
        pendingPeerIds.remove(peerIdHex)

        if accepted {
            // Notify the viewer that PIN was accepted so it clears the PIN overlay
            var confirmResponse = Peariscope_PeerChallengeResponse()
            confirmResponse.pin = pin
            confirmResponse.accepted = true
            var confirmControl = Peariscope_ControlMessage()
            confirmControl.peerChallengeResponse = confirmResponse
            if let data = try? confirmControl.serializedData(),
               let peer = networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                try? networkManager.sendControlData(data, streamId: peer.streamId)
                startStreamingToPeer(peer)
            }
        } else {
            // Disconnect the rejected peer
            Task {
                try? await networkManager.disconnect(peerKey: peerKey)
            }
        }
    }

    public func requestAccessibility() {
        InputInjector.requestAccessibilityPermission()
        Task {
            try? await Task.sleep(for: .seconds(1))
            hasAccessibilityPermission = InputInjector.hasAccessibilityPermission
        }
    }

    /// Switch codec at runtime
    public func switchCodec(toH265: Bool) {
        guard isActive, isCaptureRunning else {
            useH265 = toH265
            return
        }

        guard let display = selectedDisplay else { return }
        let width = display.width
        let height = display.height

        // Tear down current encoder
        h264Encoder?.stop()
        h264Encoder = nil
        h265Encoder?.stop()
        h265Encoder = nil

        // Create new encoder
        if toH265 && H265Encoder.isSupported {
            let enc = H265Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, _ in
                self?.sendVideoToAllPeers(data)
            }
            try? enc.start(fps: 60)
            h265Encoder = enc
        } else {
            let enc = H264Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, _ in
                self?.sendVideoToAllPeers(data)
            }
            try? enc.start(fps: 60)
            h264Encoder = enc
        }

        useH265 = toH265
        adaptiveQuality?.setCodec(toH265 ? .h265 : .h264)
        sendCodecNegotiation()
    }

    /// Restart screen capture after system stops it (e.g. error -3821)
    private func restartCapture() async {
        guard isActive, isCaptureRunning, let display = selectedDisplay else { return }
        HostSession.log("[host] Restarting capture after system stop...")
        try? await capture?.stop()
        capture = nil

        let cap = ScreenCapture()
        cap.onFrame = { [weak self] pixelBuffer, pts in
            guard let self else { return }
            self.h264Encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.h265Encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.frameCountInInterval += 1
            self.frameId += 1
            if self.frameId % 30 == 0 {
                self.sendFrameTimestamp()
            }
        }
        cap.onError = { [weak self] error in
            HostSession.log("[host] Capture error: \(error)")
            guard let self else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await self.restartCapture()
            }
        }

        do {
            try await cap.start(display: display, fps: 60)
            capture = cap
            forceKeyframe()
            HostSession.log("[host] Capture restarted successfully")
        } catch {
            HostSession.log("[host] Failed to restart capture: \(error)")
            try? await Task.sleep(for: .seconds(3))
            await restartCapture()
        }
    }

    public func forceKeyframe() {
        HostSession.log("[host] forceKeyframe called, h264=\(h264Encoder != nil ? "yes" : "nil"), h265=\(h265Encoder != nil ? "yes" : "nil")")
        h264Encoder?.forceKeyframe()
        h265Encoder?.forceKeyframe()
    }

    // MARK: - Private

    private static var sendCount = 0
    private func sendVideoToAllPeers(_ data: Data) {
        HostSession.sendCount += 1
        if HostSession.sendCount <= 5 || HostSession.sendCount % 300 == 0 {
            HostSession.log("[host-send] len=\(data.count) peers=\(networkManager.connectedPeers.count) pending=\(pendingPeerIds.count) count=\(HostSession.sendCount)")
        }
        for peer in networkManager.connectedPeers {
            guard !pendingPeerIds.contains(peer.id) else { continue }
            try? networkManager.sendVideoData(data, streamId: peer.streamId)
        }
    }

    private func applyQualitySettings(_ settings: AdaptiveQuality.Settings) {
        bitrate = settings.bitrate
        h264Encoder?.bitrate = settings.bitrate
        h265Encoder?.bitrate = settings.bitrate

        // Switch codec if needed
        if settings.codec == .h265 && h265Encoder == nil && H265Encoder.isSupported {
            switchCodec(toH265: true)
        } else if settings.codec == .h264 && h264Encoder == nil {
            switchCodec(toH265: false)
        }
    }

    /// Switch to a different display while streaming is active
    public func switchDisplay(to display: SCDisplay) async throws {
        guard isActive else {
            selectedDisplay = display
            return
        }

        HostSession.log("[host] Switching display to \(display.width)x\(display.height)")

        // Stop current capture
        try await capture?.stop()
        capture = nil

        // Update display and injector
        selectedDisplay = display
        inputInjector = InputInjector(displayWidth: display.width, displayHeight: display.height)

        // Recreate encoders for new resolution
        h264Encoder?.stop()
        h264Encoder = nil
        h265Encoder?.stop()
        h265Encoder = nil

        let width = display.width
        let height = display.height

        if useH265 && H265Encoder.isSupported {
            let enc = H265Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, isKeyframe in
                self?.sendVideoToAllPeers(data)
            }
            try enc.start(fps: 60)
            h265Encoder = enc
        } else {
            let enc = H264Encoder(width: width, height: height, fps: 60, bitrate: bitrate)
            enc.onEncodedData = { [weak self] data, isKeyframe in
                self?.sendVideoToAllPeers(data)
            }
            try enc.start(fps: 60)
            h264Encoder = enc
        }

        // Restart capture on new display
        let cap = ScreenCapture()
        cap.onFrame = { [weak self] pixelBuffer, pts in
            guard let self else { return }
            self.h264Encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.h265Encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.frameCountInInterval += 1
            self.frameId += 1
            if self.frameId % 30 == 0 {
                self.sendFrameTimestamp()
            }
        }
        cap.onError = { [weak self] error in
            HostSession.log("[host] Capture error: \(error)")
            guard let self else { return }
            Task { @MainActor in
                await self.restartCapture()
            }
        }

        try await cap.start(display: display, fps: 60)
        capture = cap
        forceKeyframe()
        sendDisplayList()
        HostSession.log("[host] Display switched to \(width)x\(height)")
    }

    /// Send list of available displays to all connected peers
    public func sendDisplayList() {
        var displayList = Peariscope_DisplayList()
        for display in availableDisplays {
            var info = Peariscope_DisplayInfo()
            info.displayID = display.displayID
            info.width = UInt32(display.width)
            info.height = UInt32(display.height)
            info.name = "\(display.width)x\(display.height)"
            info.isActive = (display.displayID == selectedDisplay?.displayID)
            displayList.displays.append(info)
        }

        var control = Peariscope_ControlMessage()
        control.displayList = displayList
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    private func handleControlMessage(_ msg: Peariscope_ControlMessage) {
        switch msg.msg {
        case .requestIdr:
            forceKeyframe()
        case .qualityReport(let report):
            adaptiveQuality?.update(stats: .init(
                rttMs: Double(report.rttMs),
                packetLoss: Double(report.packetLoss),
                throughputKbps: Double(report.bitrateKbps),
                decodeFps: Double(report.fps)
            ))
            // Track viewer screen resolution for adaptive capture scaling
            if report.screenWidth > 0 && report.screenHeight > 0 {
                // Find which peer sent this (use first connected peer as approximation)
                if let peer = networkManager.connectedPeers.first(where: { !pendingPeerIds.contains($0.id) }) {
                    let w = Int(report.screenWidth)
                    let h = Int(report.screenHeight)
                    let old = peerResolutions[peer.id]
                    if old?.width != w || old?.height != h {
                        peerResolutions[peer.id] = (width: w, height: h)
                        HostSession.log("[host] Peer \(peer.id.prefix(16)) screen: \(w)x\(h)")
                        Task { @MainActor in
                            await self.updateCaptureResolution()
                        }
                    }
                }
            }
        case .clipboard(let clipboard):
            networkManager.clipboardSharing.applyRemoteClipboard(clipboard.text)
        case .switchDisplay(let switchMsg):
            Task { @MainActor in
                if let display = self.availableDisplays.first(where: { $0.displayID == switchMsg.displayID }) {
                    try? await self.switchDisplay(to: display)
                }
            }
        case .peerChallengeResponse(let response):
            Task { @MainActor in
                guard let peerKey = self.pendingPeerKey else {
                    HostSession.log("[host] PIN response but no pending peer key")
                    return
                }
                let peerIdHex = peerKey.map { String(format: "%02x", $0) }.joined()
                let peerFP = PeerFingerprint.format(peerIdHex)

                // Check lockout
                if let lockoutDate = self.peerLockoutUntil[peerIdHex], lockoutDate > Date() {
                    let remainingSec = Int(lockoutDate.timeIntervalSinceNow)
                    HostSession.log("[host] Peer \(peerFP) is locked out for \(remainingSec)s more, rejecting")
                    // Send rejection and disconnect
                    var rejectResponse = Peariscope_PeerChallengeResponse()
                    rejectResponse.pin = response.pin
                    rejectResponse.accepted = false
                    var rejectControl = Peariscope_ControlMessage()
                    rejectControl.peerChallengeResponse = rejectResponse
                    if let data = try? rejectControl.serializedData(),
                       let peer = self.networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                        try? self.networkManager.sendControlData(data, streamId: peer.streamId)
                    }
                    self.respondToPeer(accepted: false)
                    return
                }

                if response.accepted && response.pin == self.pendingPeerPin {
                    HostSession.log("[host] PIN verified for \(peerFP)")
                    self.failedPinAttempts.removeValue(forKey: peerIdHex)
                    self.peerLockoutUntil.removeValue(forKey: peerIdHex)
                    self.respondToPeer(accepted: true)
                } else {
                    let attempts = (self.failedPinAttempts[peerIdHex] ?? 0) + 1
                    self.failedPinAttempts[peerIdHex] = attempts
                    let remaining = self.maxPinAttempts - attempts

                    if attempts >= self.maxPinAttempts {
                        self.peerLockoutUntil[peerIdHex] = Date().addingTimeInterval(self.lockoutDuration)
                        HostSession.log("[host] Peer \(peerFP) locked out for 5 minutes after \(self.maxPinAttempts) failed attempts")
                        // Send rejection and disconnect
                        var rejectResponse = Peariscope_PeerChallengeResponse()
                        rejectResponse.pin = response.pin
                        rejectResponse.accepted = false
                        var rejectControl = Peariscope_ControlMessage()
                        rejectControl.peerChallengeResponse = rejectResponse
                        if let data = try? rejectControl.serializedData(),
                           let peer = self.networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                            try? self.networkManager.sendControlData(data, streamId: peer.streamId)
                        }
                        self.respondToPeer(accepted: false)
                    } else {
                        HostSession.log("[host] PIN failed for \(peerFP) (attempt \(attempts)/\(self.maxPinAttempts))")
                        // Send rejection but DON'T disconnect — let viewer retry
                        var rejectResponse = Peariscope_PeerChallengeResponse()
                        rejectResponse.pin = response.pin
                        rejectResponse.accepted = false
                        var rejectControl = Peariscope_ControlMessage()
                        rejectControl.peerChallengeResponse = rejectResponse
                        if let data = try? rejectControl.serializedData(),
                           let peer = self.networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                            try? self.networkManager.sendControlData(data, streamId: peer.streamId)
                        }
                        // Don't call respondToPeer — peer stays pending, can retry
                    }
                }
            }
        default:
            break
        }
    }

    private func sendFrameTimestamp() {
        var ts = Peariscope_FrameTimestamp()
        ts.captureTimeMs = LatencyTracker.captureTimestamp()
        ts.frameID = frameId

        var control = Peariscope_ControlMessage()
        control.frameTimestamp = ts

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    private func sendCodecNegotiation() {
        var negotiation = Peariscope_CodecNegotiation()
        negotiation.supportedCodecs = [.h264]
        if H265Encoder.isSupported {
            negotiation.supportedCodecs.append(.h265)
        }
        negotiation.selectedCodec = useH265 ? .h265 : .h264

        var control = Peariscope_ControlMessage()
        control.codecNegotiation = negotiation

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }
}

extension HostSession {
    static func log(_ msg: String) {
        NSLog("%@", msg)
    }
}

public enum HostSessionError: Error {
    case noDisplaySelected
}

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
