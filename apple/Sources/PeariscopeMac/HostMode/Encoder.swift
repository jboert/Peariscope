import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware-accelerated H.264 encoder using VideoToolbox.
/// Configured for low-latency real-time streaming.
public final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private var frameCount: Int64 = 0
    private let queue = DispatchQueue(label: "peariscope.encoder", qos: .userInteractive)

    /// Called with encoded NAL units ready to send over the network.
    /// The Data contains an Annex B formatted H.264 bitstream (with start codes).
    public var onEncodedData: ((Data, Bool) -> Void)?  // (data, isKeyframe)

    public var bitrate: Int {
        didSet {
            guard let session else { return }
            let val = CFNumberCreate(nil, .intType, &bitrate) as CFTypeRef
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: val)
        }
    }

    public init(width: Int, height: Int, fps: Int = 60, bitrate: Int = 8_000_000) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrate
    }

    /// Create and configure the compression session
    public func start(fps: Int = 60) throws {
        let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon!).takeUnretainedValue()
            encoder.handleEncodedSample(sampleBuffer)
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        self.session = session

        // Configure for low-latency real-time encoding
        setProperty(kVTCompressionPropertyKey_RealTime, value: true)
        setProperty(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        setProperty(kVTCompressionPropertyKey_AllowFrameReordering, value: false)  // No B-frames
        setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps)  // Keyframe every 1s
        setProperty(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0)
        setProperty(kVTCompressionPropertyKey_AverageBitRate, value: bitrate)
        setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps)

        // Data rate limits: [bytes per second, seconds] — allow burst
        let limits: [Int] = [bitrate / 8 * 2, 1]
        setProperty(kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Encode a single frame
    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }

        let duration = CMTime.invalid
        var flags = VTEncodeInfoFlags()

        var frameProps: CFDictionary? = nil
        if _forceNextKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            _forceNextKeyframe = false
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        frameCount += 1
    }

    /// Force an IDR (keyframe) on the next encode
    public func forceKeyframe() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        _forceNextKeyframe = true
    }

    private var _forceNextKeyframe = false

    /// Stop the encoder
    public func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Private

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        let isKeyframe = isKeyFrame(sampleBuffer)

        // Get total encoded data length for pre-allocation
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let dataPointer else { return }

        // Pre-allocate with estimated capacity (params + start codes + data)
        var annexBData = Data(capacity: totalLength + 128)

        // If keyframe, prepend SPS and PPS
        if isKeyframe {
            if let formatDesc = sampleBuffer.formatDescription {
                annexBData.append(extractParameterSets(from: formatDesc))
            }
        }

        // Convert AVCC (length-prefixed) NAL units to Annex B (start code prefixed)
        var offset = 0

        while offset < totalLength {
            // Read 4-byte NAL unit length (AVCC format)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            nalLength = nalLength.bigEndian
            offset += 4

            // Write Annex B start code + NAL unit
            annexBData.append(contentsOf: Self.startCode)
            annexBData.append(Data(bytes: dataPointer + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }

        onEncodedData?(annexBData, isKeyframe)
    }

    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true  // Assume keyframe if no info
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private func extractParameterSets(from formatDesc: CMFormatDescription) -> Data {
        var data = Data(capacity: 128)

        // SPS
        var spsSize = 0
        var spsCount = 0
        var spsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        if let spsPointer, spsSize > 0 {
            data.append(contentsOf: Self.startCode)
            data.append(Data(bytes: spsPointer, count: spsSize))
        }

        // PPS
        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        if let ppsPointer, ppsSize > 0 {
            data.append(contentsOf: Self.startCode)
            data.append(Data(bytes: ppsPointer, count: ppsSize))
        }

        return data
    }

    private func setProperty(_ key: CFString, value: Any) {
        guard let session else { return }
        let cfValue: CFTypeRef
        switch value {
        case let b as Bool:
            cfValue = (b ? kCFBooleanTrue : kCFBooleanFalse)!
        case let i as Int:
            var v = i
            cfValue = CFNumberCreate(nil, .intType, &v)
        case let d as Double:
            var v = d
            cfValue = CFNumberCreate(nil, .doubleType, &v)
        case let s as CFString:
            cfValue = s
        case let a as CFArray:
            cfValue = a
        default:
            return
        }
        VTSessionSetProperty(session, key: key, value: cfValue)
    }
}

public enum EncoderError: Error {
    case sessionCreationFailed(OSStatus)
}
