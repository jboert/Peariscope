import Foundation
import MetalKit
import CoreMedia
import PeariscopeCore

/// Orchestrates the viewer-side pipeline: network -> decode -> render + input capture -> network
/// Supports H.264 and H.265, sends quality reports to the host.
@MainActor
public final class ViewerSession: ObservableObject {
    @Published public var isActive = false
    @Published public var fps: Double = 0
    @Published public var latency: Double = 0
    @Published public var isCapturingInput = false
    @Published public var currentCodec: String = "H.264"
    @Published public var latencyMs: Double = 0

    private var h264Decoder: H264Decoder?
    private var h265Decoder: H265Decoder?
    private var renderer: MetalRenderer?
    private var inputCapture: InputCapture?
    private let networkManager: NetworkManager
    private let latencyTracker = LatencyTracker()

    private var frameCountInInterval = 0
    private var idrRetryCount = 0
    private var fpsTimer: Timer?
    private var qualityReportTimer: Timer?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var rttEstimate: Double = 0
    private var detectedH265 = false

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    public func setup(mtkView: MTKView) {
        let h264 = H264Decoder()
        let h265 = H265Decoder()

        renderer = MetalRenderer(mtkView: mtkView)

        // Direct delivery: decoder → renderer, no intermediate buffering.
        // Capture the renderer directly to avoid accessing @MainActor-isolated
        // `self.renderer` from VideoToolbox's decoder thread (data race).
        let metalRenderer = renderer
        let onDecoded: (CVPixelBuffer, CMTime) -> Void = { [weak self] pixelBuffer, _ in
            metalRenderer?.display(pixelBuffer: pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.frameCountInInterval += 1
                self?.lastFrameTime = CFAbsoluteTimeGetCurrent()
            }
        }

        h264.onDecodedFrame = onDecoded
        h265.onDecodedFrame = onDecoded
        h264Decoder = h264
        h265Decoder = h265

        // Route video data to the correct decoder based on NAL type
        networkManager.onVideoData = { [weak self] data in
            self?.routeVideoData(data)
        }

        // Handle control messages from host
        networkManager.onControlData = { [weak self] data in
            guard let self else { return }
            if let msg = try? Peariscope_ControlMessage(serializedBytes: data) {
                self.handleControlMessage(msg)
            }
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
        capture.isCapturing = false
        inputCapture = capture
    }

    public func connect(code: String) async throws {
        try await networkManager.connect(code: code)
        isActive = true

        // FPS counter + latency update
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let frames = self.frameCountInInterval
                self.fps = Double(frames)
                self.frameCountInInterval = 0
                self.latencyMs = self.latencyTracker.averageLatencyMs
                // Re-request keyframe if no frames decoded for 2+ seconds
                if frames == 0 && self.isActive {
                    self.idrRetryCount += 1
                    if self.idrRetryCount >= 2 && self.idrRetryCount <= 10 {
                        self.requestIDR()
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

    /// Request a keyframe from the host
    public func requestIDR() {
        var control = Peariscope_ControlMessage()
        control.requestIdr = Peariscope_RequestIdr()
        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }

    public func disconnect() {
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
        renderer?.stop()
        renderer = nil
        isActive = false
        fps = 0
        latencyMs = 0
        isCapturingInput = false
    }

    // MARK: - Private

    /// Detect codec from NAL units and route to correct decoder.
    /// Once H.265 VPS/SPS/PPS is detected, all subsequent frames go to the H.265 decoder.
    private func routeVideoData(_ data: Data) {
        guard data.count >= 5 else { return }

        if detectedH265 {
            h265Decoder?.decode(annexBData: data)
            return
        }

        // Find first NAL unit after start code to detect codec
        let bytes = Array(data)
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                let nalByte = bytes[i+4]
                // H.265: NAL type is bits 1-6 of first byte
                let h265Type = (nalByte >> 1) & 0x3F

                if h265Type >= 32 && h265Type <= 34 {
                    // VPS/SPS/PPS — definitely HEVC, lock in
                    detectedH265 = true
                    currentCodec = "H.265"
                    h265Decoder?.decode(annexBData: data)
                    return
                }
                break
            }
            i += 1
        }

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
            networkManager.clipboardSharing.applyRemoteClipboard(clipboard.text)
        case .frameTimestamp(let ts):
            _ = latencyTracker.measureFromTimestamp(ts.captureTimeMs)
        default:
            break
        }
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

        var control = Peariscope_ControlMessage()
        control.qualityReport = report

        guard let data = try? control.serializedData() else { return }
        for peer in networkManager.connectedPeers {
            try? networkManager.sendControlData(data, streamId: peer.streamId)
        }
    }
}
