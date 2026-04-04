import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures the screen using ScreenCaptureKit with low-latency configuration.
public final class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private let queue = DispatchQueue(label: "peariscope.capture", qos: .userInteractive)

    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onAudioSample: ((CMSampleBuffer) -> Void)?
    public var onError: ((Error) -> Void)?

    /// Count of frames skipped due to unchanged content (diagnostics)
    public var skippedFrameCount: Int = 0

    /// Available displays
    public static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    /// Start capturing a specific display
    public func start(display: sending SCDisplay, fps: Int = 60, resolution: CGSize? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Exclude our own app windows
        let excludedApps = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let width = Int(resolution?.width ?? CGFloat(display.width))
        let height = Int(resolution?.height ?? CGFloat(display.height))

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false  // Cursor rendered client-side from CursorPosition messages
        config.capturesAudio = true

        let stream = SCStream(filter: filter!, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()

        self.stream = stream
    }

    /// Stop capturing
    public func stop() async throws {
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }
    }

    /// Update capture resolution (for adaptive quality)
    public func updateResolution(width: Int, height: Int, fps: Int = 60) async throws {
        guard let stream else { return }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = true
        try await stream.updateConfiguration(config)
    }
}

extension ScreenCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

extension ScreenCapture: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // Check for idle frames (no new content)
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else {
                return
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // SCFrameStatus.complete already filters unchanged frames — no additional
            // content hashing needed. Trust ScreenCaptureKit's built-in change detection.
            onFrame?(pixelBuffer, pts)

        case .audio:
            onAudioSample?(sampleBuffer)

        @unknown default:
            break
        }
    }
}
