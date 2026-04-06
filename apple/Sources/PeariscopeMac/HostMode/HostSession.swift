import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import PeariscopeCore
import os.log
import AVFoundation
import Security

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
    @Published public var hasScreenRecordingPermission = true
    @Published public var useH265 = false
    @Published public var adaptiveQualityEnabled = true
    @Published public var pendingPeerPin: String?
    @Published public var pendingPeerKey: Data?
    @Published public var pendingPeerFingerprint: String?
    /// Peers awaiting PIN verification — no video/input sent until approved
    private var pendingPeerIds: Set<String> = []
    /// Peers that passed PIN verification — auto-approve on reconnect
    private var approvedPeerIds: Set<String> = []
    // PIN brute-force protection
    private var failedPinAttempts: [String: Int] = [:]
    private var peerLockoutUntil: [String: Date] = [:]
    private let maxPinAttempts = 5
    private let lockoutDuration: TimeInterval = 300
    private var globalFailedPinAttempts = 0
    private var globalLockoutUntil: Date?
    @Published public var requirePinVerification: Bool {
        didSet { UserDefaults.standard.set(requirePinVerification, forKey: "peariscope.requirePin") }
    }
    @Published public var pinCode: String {
        didSet { Self.savePinToKeychain(pinCode) }
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
    @Published public var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "peariscope.audioEnabled")
            if audioEnabled {
                startAudioCapture()
            } else {
                stopAudioCapture()
            }
        }
    }
    public var adaptiveResolutionEnabled: Bool {
        didSet { UserDefaults.standard.set(adaptiveResolutionEnabled, forKey: "peariscope.adaptiveResolution") }
    }

    private var capture: ScreenCapture?
    private var h264Encoder: H264Encoder?
    private var h265Encoder: H265Encoder?
    private var audioEncoder: AudioEncoder?
    private var inputInjector: InputInjector?
    private var adaptiveQuality: AdaptiveQuality?
    private let networkManager: NetworkManager
    private let localAdvertiser = LocalDiscoveryAdvertiser()
    /// True when screen capture + encoders are running (peers are connected)
    private var isCaptureRunning = false

    private var frameCountInInterval = 0
    private var frameId: UInt32 = 0
    private var fpsTimer: Timer?
    private var pingTimer: Timer?
    private var lastMeasuredRtt: Double = 0
    private var cursorTimer: Timer?
    private var lastCursorX: Float = -1
    private var lastCursorY: Float = -1
    /// Auto-dismiss pending PIN prompt if the viewer disconnects without a clean signal
    private var pendingPeerTimeoutTimer: Timer?

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
        self.pinCode = Self.loadPinFromKeychain()
        let savedMaxViewers = UserDefaults.standard.integer(forKey: "peariscope.maxViewers")
        self.maxViewers = savedMaxViewers > 0 ? savedMaxViewers : 5
        // Default to enabled; user can disable if it causes issues
        self.adaptiveResolutionEnabled = UserDefaults.standard.object(forKey: "peariscope.adaptiveResolution") as? Bool ?? true
        self.audioEnabled = UserDefaults.standard.object(forKey: "peariscope.audioEnabled") as? Bool ?? true
    }

    public func refreshDisplays() async throws {
        availableDisplays = try await ScreenCapture.availableDisplays()
        if selectedDisplay == nil {
            selectedDisplay = availableDisplays.first
        }
    }

    public func start() async throws {
        HostSession.log("[host] start() called, selectedDisplay=\(selectedDisplay != nil), isActive=\(isActive)")
        // Check Screen Recording permission early — if denied, fail fast instead of
        // silently producing no video after viewers connect.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            hasScreenRecordingPermission = true
        } catch {
            let nsError = error as NSError
            if nsError.code == -3801 {
                hasScreenRecordingPermission = false
                networkManager.lastError = "Screen Recording permission denied. Open System Settings → Privacy & Security → Screen Recording and enable Peariscope."
                HostSession.log("[host] start() FAILED: Screen Recording permission denied")
                throw error
            }
        }

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
            guard let self else { return }
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
                // Periodic keyframe every 3 seconds for viewer recovery
                if self.isCaptureRunning && self.frameId > 0 && self.frameId % (60 * 3) < 60 {
                    self.forceKeyframe()
                }
            }
        }

        // RTT ping timer — send ping every 2 seconds, viewers echo as pong
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sendPing()
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

            // Auto-approve previously verified peers on reconnect (connection recovery).
            // Disabled by default — must be enabled in settings.
            let skipPinOnReconnect = UserDefaults.standard.bool(forKey: "peariscope.skipPinOnReconnect")
            if skipPinOnReconnect && self.approvedPeerIds.contains(peer.id) {
                HostSession.log("[host] Auto-approving previously verified peer: \(fingerprint)")
                self.startStreamingToPeer(peer)
                return
            }

            HostSession.log("[host] PIN check: requirePin=\(self.requirePinVerification) pinLen=\(self.pinCode.count)")
            if self.requirePinVerification && self.pinCode.count >= 6 {
                // Block this peer from receiving video/input/control/audio until PIN verified
                self.pendingPeerIds.insert(peer.id)
                self.networkManager.blockedStreamIds.insert(peer.streamId)
                self.pendingPeerPin = self.pinCode
                self.pendingPeerKey = Data(hex: peer.id)
                self.pendingPeerFingerprint = fingerprint

                var challenge = Peariscope_PeerChallenge()
                // Don't send the actual PIN — a modified client could read it
                // and auto-approve. The viewer prompts for PIN entry and the
                // host verifies the response server-side.
                challenge.peerKey = Data(hex: peer.id)
                var control = Peariscope_ControlMessage()
                control.peerChallenge = challenge
                if let data = try? control.serializedData() {
                    HostSession.log("[host] Sending PIN challenge: \(data.count) bytes to streamId=\(peer.streamId)")
                    try? self.networkManager.sendControlData(data, streamId: peer.streamId)
                    HostSession.log("[host] PIN challenge sent successfully")
                } else {
                    HostSession.log("[host] FAILED to serialize PIN challenge")
                }
                HostSession.log("[host] Sent PIN challenge to peer: \(fingerprint), blocking video until verified")
                // Auto-dismiss after 30s if peer silently disconnects (no clean disconnect event)
                self.pendingPeerTimeoutTimer?.invalidate()
                self.pendingPeerTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.pendingPeerPin != nil else { return }
                        HostSession.log("[host] PIN prompt timed out after 30s, auto-dismissing")
                        self.respondToPeer(accepted: false)
                    }
                }
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
                self.networkManager.blockedStreamIds.remove(peer.streamId)
                if self.pendingPeerKey == Data(hex: peer.id) {
                    self.pendingPeerPin = nil
                    self.pendingPeerKey = nil
                    self.pendingPeerFingerprint = nil
                    self.pendingPeerTimeoutTimer?.invalidate()
                    self.pendingPeerTimeoutTimer = nil
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

        // Start Bonjour advertising so iOS viewers on the same WiFi can discover us.
        // Include publicKeyHex and dhtPort so viewers can fast-connect via LAN.
        if let code = networkManager.connectionCode {
            let hostName = Host.current().localizedName ?? "Mac"
            localAdvertiser.start(code: code, name: hostName,
                                  publicKeyHex: networkManager.hostPublicKeyHex,
                                  dhtPort: networkManager.hostDhtPort)
        }
        // Also watch for connectionCode updates (e.g., recovered from status response)
        Task { @MainActor in
            // Brief delay to allow connectionCode recovery from worklet
            try? await Task.sleep(for: .seconds(3))
            if let code = self.networkManager.connectionCode, !self.localAdvertiser.isAdvertising {
                let hostName = Host.current().localizedName ?? "Mac"
                self.localAdvertiser.start(code: code, name: hostName,
                                           publicKeyHex: self.networkManager.hostPublicKeyHex,
                                           dhtPort: self.networkManager.hostDhtPort)
            }
        }
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
            if audioEnabled { startAudioCapture() }
            HostSession.log("[host] Capture started successfully")
        } catch {
            HostSession.log("[host] Failed to start capture: \(error)")
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801 {
                hasScreenRecordingPermission = false
                networkManager.lastError = "Screen Recording permission denied. Open System Settings → Privacy & Security → Screen Recording and enable Peariscope."
                HostSession.log("[host] Screen Recording TCC denied — surfacing error to user")
            } else {
                networkManager.lastError = "Screen capture failed: \(error.localizedDescription)"
            }
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
        audioEncoder?.stop()
        audioEncoder = nil

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

        // Always capture at native resolution — the encoder preserves full detail
        // and the viewer downscales on GPU (sharp). Pre-downscaling causes blur.
        let targetW = displayW
        let targetH = displayH

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
        pingTimer?.invalidate()
        pingTimer = nil
        inputRateLimitTimer?.invalidate()
        inputRateLimitTimer = nil

        await stopCapture()

        inputInjector = nil
        networkManager.onInputData = nil
        networkManager.onControlData = nil
        networkManager.onPeerConnected = nil
        networkManager.onPeerDisconnected = nil
        pendingPeerIds.removeAll()
        networkManager.blockedStreamIds.removeAll()
        pendingPeerPin = nil
        pendingPeerKey = nil
        pendingPeerFingerprint = nil
        peerResolutions.removeAll()

        localAdvertiser.stop()
        try await networkManager.stopHosting()
        isActive = false
    }

    /// Begin sending video/codec/display info to a verified peer
    private func startStreamingToPeer(_ peer: NetworkManager.PeerState) {
        // Remember approved peer so they skip PIN on reconnect
        approvedPeerIds.insert(peer.id)
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
        HostSession.log("[host] Peer \(accepted ? "approved" : "rejected") pinLen=\(pin.count), peerIdHex=\(peerIdHex.prefix(16))")
        pendingPeerPin = nil
        pendingPeerKey = nil
        pendingPeerFingerprint = nil
        pendingPeerIds.remove(peerIdHex)
        // Unblock this peer's stream so input/control/audio can flow
        if let peer = networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
            networkManager.blockedStreamIds.remove(peer.streamId)
        }
        pendingPeerTimeoutTimer?.invalidate()
        pendingPeerTimeoutTimer = nil

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
                HostSession.log("[host] respondToPeer: sent confirmation and starting stream for \(peerIdHex.prefix(16))")
                startStreamingToPeer(peer)
            } else {
                HostSession.log("[host] respondToPeer: FAILED to find peer \(peerIdHex.prefix(16)) in connectedPeers (count=\(networkManager.connectedPeers.count), ids=\(networkManager.connectedPeers.map { $0.id.prefix(16) }))")
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
            if audioEnabled { startAudioCapture() }
            forceKeyframe()
            HostSession.log("[host] Capture restarted successfully")
        } catch {
            HostSession.log("[host] Failed to restart capture: \(error)")
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801 {
                hasScreenRecordingPermission = false
                networkManager.lastError = "Screen Recording permission denied. Open System Settings → Privacy & Security → Screen Recording and enable Peariscope."
            } else {
                try? await Task.sleep(for: .seconds(3))
                await restartCapture()
            }
        }
    }

    public func forceKeyframe() {
        HostSession.log("[host] forceKeyframe called, h264=\(h264Encoder != nil ? "yes" : "nil"), h265=\(h265Encoder != nil ? "yes" : "nil")")
        h264Encoder?.forceKeyframe()
        h265Encoder?.forceKeyframe()
    }

    // MARK: - Private

    private func startAudioCapture() {
        guard isCaptureRunning, audioEncoder == nil else { return }
        let audioEnc = AudioEncoder(sampleRate: 48000, channels: 2)
        audioEnc.onEncodedData = { [weak self] data in
            self?.sendAudioToAllPeers(data)
        }
        do {
            try audioEnc.start()
            audioEncoder = audioEnc
            capture?.onAudioSample = { [weak self] sampleBuffer in
                self?.audioEncoder?.encode(sampleBuffer: sampleBuffer)
            }
            HostSession.log("[host] Audio encoder started")
        } catch {
            HostSession.log("[host] Audio encoder failed: \(error)")
        }
    }

    private func stopAudioCapture() {
        capture?.onAudioSample = nil
        audioEncoder?.stop()
        audioEncoder = nil
        HostSession.log("[host] Audio encoder stopped")
    }

    private func sendAudioToAllPeers(_ data: Data) {
        for peer in networkManager.connectedPeers {
            guard !pendingPeerIds.contains(peer.id) else { continue }
            try? networkManager.sendAudioData(data, streamId: peer.streamId)
        }
    }

    private func sendVideoToAllPeers(_ data: Data) {
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
        if audioEnabled { startAudioCapture() }
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
        case .pong(let pong):
            handlePong(pong)
        case .ping:
            break  // Host doesn't respond to pings
        case .qualityReport(let report):
            adaptiveQuality?.update(stats: .init(
                rttMs: lastMeasuredRtt,  // Use actual RTT from ping/pong
                packetLoss: Double(report.packetLoss),
                throughputKbps: Double(report.bitrateKbps),
                decodeFps: Double(report.fps),
                receivedKbps: Double(report.receivedKbps),
                jitterMs: Double(report.jitterMs)
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
            if !clipboard.imagePng.isEmpty {
                networkManager.clipboardSharing.applyRemoteImage(clipboard.imagePng)
            } else {
                networkManager.clipboardSharing.applyRemoteClipboard(clipboard.text)
            }
        case .switchDisplay(let switchMsg):
            Task { @MainActor in
                if let display = self.availableDisplays.first(where: { $0.displayID == switchMsg.displayID }) {
                    try? await self.switchDisplay(to: display)
                }
            }
        case .codecNegotiation(let negotiation):
            // Viewer is requesting a codec change (e.g., H.265 decode failing)
            if negotiation.selectedCodec == .h264 && useH265 {
                HostSession.log("[host] Viewer requested codec fallback to H.264")
                switchCodec(toH265: false)
            }
        case .peerChallengeResponse(let response):
            HostSession.log("[host] Received PIN response: pinMatch=\(response.pin == pendingPeerPin) hasPeerKey=\(pendingPeerKey != nil) pendingPeerIds=\(pendingPeerIds.count) connectedPeers=\(networkManager.connectedPeers.count)")
            guard let peerKey = pendingPeerKey else {
                HostSession.log("[host] PIN response but no pending peer key — was it already cleared?")
                return
            }
            let peerIdHex = peerKey.map { String(format: "%02x", $0) }.joined()
            let peerFP = PeerFingerprint.format(peerIdHex)

            // Check global lockout
            if let globalLockout = globalLockoutUntil, globalLockout > Date() {
                let remainingSec = Int(globalLockout.timeIntervalSinceNow)
                HostSession.log("[host] Global lockout active for \(remainingSec)s more, rejecting \(peerFP)")
                var rejectResponse = Peariscope_PeerChallengeResponse()
                rejectResponse.pin = response.pin
                rejectResponse.accepted = false
                var rejectControl = Peariscope_ControlMessage()
                rejectControl.peerChallengeResponse = rejectResponse
                if let data = try? rejectControl.serializedData(),
                   let peer = networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                    try? networkManager.sendControlData(data, streamId: peer.streamId)
                }
                respondToPeer(accepted: false)
                return
            }

            // Check per-peer lockout
            if let lockoutDate = peerLockoutUntil[peerIdHex], lockoutDate > Date() {
                let remainingSec = Int(lockoutDate.timeIntervalSinceNow)
                HostSession.log("[host] Peer \(peerFP) is locked out for \(remainingSec)s more, rejecting")
                var rejectResponse = Peariscope_PeerChallengeResponse()
                rejectResponse.pin = response.pin
                rejectResponse.accepted = false
                var rejectControl = Peariscope_ControlMessage()
                rejectControl.peerChallengeResponse = rejectResponse
                if let data = try? rejectControl.serializedData(),
                   let peer = networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                    try? networkManager.sendControlData(data, streamId: peer.streamId)
                }
                respondToPeer(accepted: false)
                return
            }

            HostSession.log("[host] PIN check: pinMatch=\(response.pin == pendingPeerPin)")
            if response.pin == pendingPeerPin {
                HostSession.log("[host] PIN verified for \(peerFP)")
                failedPinAttempts.removeValue(forKey: peerIdHex)
                peerLockoutUntil.removeValue(forKey: peerIdHex)
                respondToPeer(accepted: true)
            } else {
                let attempts = (failedPinAttempts[peerIdHex] ?? 0) + 1
                failedPinAttempts[peerIdHex] = attempts
                globalFailedPinAttempts += 1
                if globalFailedPinAttempts >= maxPinAttempts * 3 {
                    globalLockoutUntil = Date().addingTimeInterval(lockoutDuration * 2)
                    HostSession.log("[host] Global lockout triggered after \(globalFailedPinAttempts) total failed attempts")
                }

                if attempts >= maxPinAttempts {
                    peerLockoutUntil[peerIdHex] = Date().addingTimeInterval(lockoutDuration)
                    HostSession.log("[host] Peer \(peerFP) locked out for 5 minutes after \(maxPinAttempts) failed attempts")
                    var rejectResponse = Peariscope_PeerChallengeResponse()
                    rejectResponse.pin = response.pin
                    rejectResponse.accepted = false
                    var rejectControl = Peariscope_ControlMessage()
                    rejectControl.peerChallengeResponse = rejectResponse
                    if let data = try? rejectControl.serializedData(),
                       let peer = networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                        try? networkManager.sendControlData(data, streamId: peer.streamId)
                    }
                    respondToPeer(accepted: false)
                } else {
                    HostSession.log("[host] PIN failed for \(peerFP) (attempt \(attempts)/\(maxPinAttempts))")
                    var rejectResponse = Peariscope_PeerChallengeResponse()
                    rejectResponse.pin = response.pin
                    rejectResponse.accepted = false
                    var rejectControl = Peariscope_ControlMessage()
                    rejectControl.peerChallengeResponse = rejectResponse
                    if let data = try? rejectControl.serializedData(),
                       let peer = networkManager.connectedPeers.first(where: { $0.id == peerIdHex }) {
                        try? networkManager.sendControlData(data, streamId: peer.streamId)
                    }
                    // Don't call respondToPeer — peer stays pending, can retry
                }
            }
        default:
            break
        }
    }

    private func sendPing() {
        var ping = Peariscope_Ping()
        ping.timestampMs = UInt64(CFAbsoluteTimeGetCurrent() * 1000)

        var control = Peariscope_ControlMessage()
        control.ping = ping

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    private func handlePong(_ pong: Peariscope_Pong) {
        let now = UInt64(CFAbsoluteTimeGetCurrent() * 1000)
        let rtt = Double(now) - Double(pong.timestampMs)
        if rtt >= 0 && rtt < 10000 {  // Sanity check: 0-10s
            lastMeasuredRtt = rtt
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
    // MARK: - PIN Keychain Helpers

    private static func savePinToKeychain(_ pin: String) {
        let service = "com.peariscope.keys"
        let account = "pin-code"
        let data = Data(pin.utf8)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadPinFromKeychain() -> String {
        let service = "com.peariscope.keys"
        let account = "pin-code"
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
              let pin = String(data: data, encoding: .utf8) else {
            return ""
        }
        return pin
    }

    private static let logFile: FileHandle? = {
        let path = NSTemporaryDirectory() + "peariscope-host.log"
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ msg: String) {
        NSLog("%@", msg)
        let ts = ISO8601DateFormatter().string(from: Date())
        if let data = "[\(ts)] \(msg)\n".data(using: .utf8) {
            logFile?.seekToEndOfFile()
            logFile?.write(data)
        }
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
