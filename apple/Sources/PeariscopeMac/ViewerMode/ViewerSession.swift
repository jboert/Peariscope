import Foundation
import MetalKit
import CoreMedia
import PeariscopeCore
import AVFoundation

/// Orchestrates the viewer-side pipeline: network -> decode -> render + input capture -> network
/// Supports H.264 and H.265, sends quality reports to the host.
@MainActor
public final class ViewerSession: ObservableObject {
    @Published public var isActive = false
    @Published public var fps: Double = 0
    @Published public var latency: Double = 0
    @Published public var bandwidthBytesPerSec: Int64 = 0
    @Published public var isCapturingInput = false
    @Published public var currentCodec: String = "H.264"
    @Published public var latencyMs: Double = 0
    @Published public var videoSize: CGSize?
    @Published public var pendingPin: String?
    @Published public var pinEntryText: String = ""
    @Published public var hostFingerprint: String?
    @Published public var isReconnecting = false
    @Published public var connectionLost = false

    private var lastCode: String?
    private var reconnectAttempt = 0
    private var intentionalDisconnect = false

    private var h264Decoder: H264Decoder?
    private var h265Decoder: H265Decoder?
    private var audioPlayer: AudioPlayer?
    private var renderer: MetalRenderer?
    private var inputCapture: InputCapture?
    private let networkManager: NetworkManager
    private let latencyTracker = LatencyTracker()

    private var frameCountInInterval = 0
    nonisolated(unsafe) private var bytesReceivedInInterval: Int64 = 0
    private let bytesLock = NSLock()
    private var idrRetryCount = 0
    private var fpsTimer: Timer?
    private var qualityReportTimer: Timer?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var rttEstimate: Double = 0
    private var detectedH265 = false

    // Jitter tracking
    nonisolated(unsafe) private var lastFrameArrival: CFAbsoluteTime = 0
    nonisolated(unsafe) private var frameIntervals: [Double] = []
    private let jitterLock = NSLock()

    /// Thread-safe bandwidth byte counting.
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

    public var bandwidthFormatted: String {
        let bytes = bandwidthBytesPerSec
        if bytes >= 1_000_000 {
            return String(format: "%.1fMB/s", Double(bytes) / 1_000_000.0)
        } else if bytes >= 1_000 {
            return "\(bytes / 1_000)KB/s"
        }
        return ""
    }

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    public func setup(mtkView: MTKView) {
        let h264 = H264Decoder()
        let h265 = H265Decoder()

        renderer = MetalRenderer(mtkView: mtkView)

        let metalRenderer = renderer
        let onDecoded: (CVPixelBuffer, CMTime) -> Void = { [weak self] pixelBuffer, _ in
            metalRenderer?.display(pixelBuffer: pixelBuffer)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.frameCountInInterval += 1
                self?.lastFrameTime = CFAbsoluteTimeGetCurrent()
                self?.recordFrameArrival()
                if self?.videoSize == nil {
                    self?.videoSize = CGSize(width: w, height: h)
                }
            }
        }

        h264.onDecodedFrame = onDecoded
        h265.onDecodedFrame = onDecoded

        h265.onCodecFallbackNeeded = { [weak self] in
            DispatchQueue.main.async {
                self?.requestCodecFallback()
            }
        }

        h264Decoder = h264
        h265Decoder = h265

        // Route video data to the correct decoder based on NAL type
        networkManager.onVideoData = { [weak self] data in
            self?.addReceivedBytes(data.count)
            self?.routeVideoData(data)
        }

        // Handle control messages from host
        networkManager.onControlData = { [weak self] data in
            guard let self else { return }
            if let msg = try? Peariscope_ControlMessage(serializedBytes: data) {
                self.handleControlMessage(msg)
            }
        }

        // Set up audio playback
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

        // Set up input capture
        let capture = InputCapture()
        capture.onInputEvent = { [weak self] event in
            guard let self, let data = encodeInputEvent(event) else { return }
            for peer in self.networkManager.connectedPeers {
                try? self.networkManager.sendInputData(data, streamId: peer.streamId)
            }
        }
        capture.start(in: mtkView)
        capture.isCapturing = true
        isCapturingInput = true
        inputCapture = capture

        // Request IDR now that decoders + renderer are ready.
        // The initial keyframe was likely missed (arrives before setup).
        requestIDR()
    }

    public func connect(code: String) async throws {
        lastCode = code
        intentionalDisconnect = false
        connectionLost = false
        isReconnecting = false
        reconnectAttempt = 0
        try await networkManager.connect(code: code)
        isActive = true

        // Auto-reconnect on unexpected disconnect
        networkManager.onPeerDisconnected = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if !self.intentionalDisconnect && self.isActive {
                    self.attemptReconnect()
                }
            }
        }

        // FPS counter + latency update
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let frames = self.frameCountInInterval
                self.fps = Double(frames)
                self.frameCountInInterval = 0
                self.latencyMs = self.latencyTracker.averageLatencyMs
                self.bandwidthBytesPerSec = self.resetReceivedBytes()
                // Re-request keyframe if no frames decoded for 2+ seconds
                if frames == 0 && self.isActive {
                    self.idrRetryCount += 1
                    // Request IDR every 2 seconds while frozen, no upper limit.
                    // Also recreate VT session every 10s to recover from stuck state.
                    if self.idrRetryCount >= 2 {
                        self.requestIDR()
                        if self.idrRetryCount % 10 == 0 {
                            self.h264Decoder?.resetSession()
                            self.h265Decoder?.resetSession()
                        }
                    }
                } else if frames > 0 {
                    self.idrRetryCount = 0
                }
            }
        }

        // Quality report timer — send stats to host every 2 seconds
        qualityReportTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sendQualityReport()
            }
        }
    }

    public func toggleInputCapture() {
        inputCapture?.toggle()
        isCapturingInput = inputCapture?.isCapturing ?? false
    }

    public func submitPin() {
        var response = Peariscope_PeerChallengeResponse()
        response.pin = pinEntryText
        response.accepted = true
        var control = Peariscope_ControlMessage()
        control.peerChallengeResponse = response
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
        NSLog("[viewer] Submitted PIN: %@", pinEntryText)
    }

    /// Request a keyframe from the host
    public func requestIDR() {
        var control = Peariscope_ControlMessage()
        control.requestIdr = Peariscope_RequestIdr()
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    /// Request the host to switch from H.265 to H.264 due to decode failures
    private func requestCodecFallback() {
        NSLog("[viewer] CODEC FALLBACK: H.265 decode failing, requesting H.264")
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
        currentCodec = "H.264"
    }

    public func disconnect() {
        intentionalDisconnect = true
        isReconnecting = false
        connectionLost = false
        networkManager.onPeerDisconnected = nil

        fpsTimer?.invalidate()
        fpsTimer = nil
        qualityReportTimer?.invalidate()
        qualityReportTimer = nil

        inputCapture?.stop()
        inputCapture = nil

        h264Decoder?.stop()
        h264Decoder = nil
        h265Decoder?.stop()
        h265Decoder = nil
        audioPlayer?.stop()
        audioPlayer = nil
        networkManager.onAudioData = nil
        renderer?.stop()
        renderer = nil
        isActive = false
        fps = 0
        latencyMs = 0
        isCapturingInput = false
        videoSize = nil
        pendingPin = nil
        pinEntryText = ""
        hostFingerprint = nil
    }

    // MARK: - Auto-reconnect

    private func attemptReconnect() {
        guard let code = lastCode, !isReconnecting, isActive else { return }
        guard networkManager.connectedPeers.isEmpty else { return }

        isReconnecting = true
        reconnectAttempt = 0
        NSLog("[viewer] Connection lost, attempting auto-reconnect...")
        doReconnectAttempt(code: code)
    }

    private func doReconnectAttempt(code: String) {
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let maxAttempts = 5
        let delay = Double(min(attempt, 5)) * 2.0 // 2s, 4s, 6s, 8s, 10s

        if attempt > maxAttempts {
            NSLog("[viewer] Reconnect gave up after %d attempts", maxAttempts)
            isReconnecting = false
            connectionLost = true
            return
        }

        NSLog("[viewer] Reconnect attempt %d/%d (delay %.0fs)", attempt, maxAttempts, delay)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard self.isReconnecting, self.isActive else { return }

            do {
                try await self.networkManager.connect(code: code)
                NSLog("[viewer] Reconnect succeeded on attempt %d", attempt)
                self.isReconnecting = false
                self.connectionLost = false
                // Reset codec detection so we pick up whatever the host sends
                self.detectedH264 = false
                self.detectedH265 = false
                self.requestIDR()
            } catch {
                NSLog("[viewer] Reconnect attempt %d failed: %@", attempt, error.localizedDescription)
                if self.isReconnecting {
                    self.doReconnectAttempt(code: code)
                }
            }
        }
    }

    // MARK: - Private

    /// Detect codec from NAL units and route to correct decoder.
    /// Once codec is detected, all subsequent frames go to that decoder.
    private var detectedH264 = false

    private func routeVideoData(_ data: Data) {
        guard data.count >= 5 else { return }

        if detectedH265 {
            h265Decoder?.decode(annexBData: data)
            return
        }

        if detectedH264 {
            h264Decoder?.decode(annexBData: data)
            return
        }

        // Detect codec from first NAL unit after start code.
        // Must check H.264 NAL type (5 bits) BEFORE H.265 (6 bits) because
        // H.264 P-frame byte 0x41 has H.265 type = 32 (VPS), causing false detection.
        let bytes = Array(data)
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                let nalByte = bytes[i+4]
                let h264Type = nalByte & 0x1F

                // H.264 SPS/PPS/IDR → lock in H.264
                if h264Type == 7 || h264Type == 8 || h264Type == 5 {
                    detectedH264 = true
                    currentCodec = "H.264"
                    h264Decoder?.decode(annexBData: data)
                    return
                }

                // H.265 VPS/SPS/PPS: NAL type in bits 1-6, but ONLY if
                // the H.264 type doesn't match a known H.264 type first
                let h265Type = (nalByte >> 1) & 0x3F
                if h265Type >= 32 && h265Type <= 34 && h264Type > 12 {
                    detectedH265 = true
                    currentCodec = "H.265"
                    h265Decoder?.decode(annexBData: data)
                    return
                }
                break
            }
            i += 1
        }

        // Default to H.264 for unknown NAL types
        h264Decoder?.decode(annexBData: data)
    }

    private func handleControlMessage(_ msg: Peariscope_ControlMessage) {
        switch msg.msg {
        case .codecNegotiation(let negotiation):
            switch negotiation.selectedCodec {
            case .h265:
                detectedH265 = true
                currentCodec = "H.265"
            default:
                detectedH265 = false
                currentCodec = "H.264"
            }
        case .clipboard(let clipboard):
            if !clipboard.imagePng.isEmpty {
                networkManager.clipboardSharing.applyRemoteImage(clipboard.imagePng)
            } else {
                networkManager.clipboardSharing.applyRemoteClipboard(clipboard.text)
            }
        case .frameTimestamp(let ts):
            _ = latencyTracker.measureFromTimestamp(ts.captureTimeMs)
        case .peerChallenge(let challenge):
            NSLog("[viewer] PIN challenge received")
            pendingPin = "pending"
            pinEntryText = ""
            // Disable input capture so keyboard goes to PIN text field
            inputCapture?.isCapturing = false
            isCapturingInput = false
            if !challenge.peerKey.isEmpty {
                let hexKey = challenge.peerKey.map { String(format: "%02x", $0) }.joined()
                hostFingerprint = PeerFingerprint.format(hexKey)
            }
        case .peerChallengeResponse(let response):
            NSLog("[viewer] PIN response: accepted=%d", response.accepted)
            if response.accepted {
                pendingPin = nil
                hostFingerprint = nil
                // Re-enable input capture
                inputCapture?.isCapturing = true
                isCapturingInput = true
                requestIDR()
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
            break
        default:
            break
        }
    }

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
        report.rttMs = UInt32(rttEstimate)
        report.bitrateKbps = 0
        // Send screen resolution so host can adapt capture size
        if let screen = NSScreen.main {
            let backing = screen.backingScaleFactor
            report.screenWidth = UInt32(screen.frame.width * backing)
            report.screenHeight = UInt32(screen.frame.height * backing)
        }
        report.receivedKbps = UInt32(bandwidthBytesPerSec * 8 / 1000)
        report.jitterMs = Float(computeJitterMs())

        var control = Peariscope_ControlMessage()
        control.qualityReport = report

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }
}
