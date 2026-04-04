import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware-accelerated H.265/HEVC encoder using VideoToolbox.
/// Same interface as H264Encoder but uses HEVC codec for ~30-40% better compression.
public final class H265Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private var frameCount: Int64 = 0
    private var _forceNextKeyframe = false

    public var onEncodedData: ((Data, Bool) -> Void)?

    public var bitrate: Int {
        didSet {
            guard let session else { return }
            var val = bitrate
            let cfVal = CFNumberCreate(nil, .intType, &val)!
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: cfVal)
        }
    }

    public init(width: Int, height: Int, fps: Int = 60, bitrate: Int = 6_000_000) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrate
    }

    /// Check if HEVC hardware encoding is available
    public static var isSupported: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    }

    public func start(fps: Int = 60) throws {
        let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            let encoder = Unmanaged<H265Encoder>.fromOpaque(refcon!).takeUnretainedValue()
            encoder.handleEncodedSample(sampleBuffer)
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
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

        setProperty(kVTCompressionPropertyKey_RealTime, value: true)
        setProperty(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        setProperty(kVTCompressionPropertyKey_AllowFrameReordering, value: false)
        setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps)  // Keyframe every 1s
        setProperty(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0)
        setProperty(kVTCompressionPropertyKey_AverageBitRate, value: bitrate)
        setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps)

        let limits: [Int] = [bitrate / 8 * 2, 1]
        setProperty(kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }

        var frameProps: CFDictionary? = nil
        if _forceNextKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            _forceNextKeyframe = false
        }

        var flags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        frameCount += 1
    }

    public func forceKeyframe() {
        guard session != nil else { return }
        _forceNextKeyframe = true
    }

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

        let isKeyframe = !((CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        // Get total encoded data length for pre-allocation
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let dataPointer else { return }

        // Pre-allocate with estimated capacity
        var annexBData = Data(capacity: totalLength + 128)

        // Extract VPS, SPS, PPS for keyframes
        if isKeyframe, let formatDesc = sampleBuffer.formatDescription {
            for i in 0..<3 {  // VPS=0, SPS=1, PPS=2
                var paramSize = 0
                var paramPointer: UnsafePointer<UInt8>?
                let paramStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc, parameterSetIndex: i,
                    parameterSetPointerOut: &paramPointer, parameterSetSizeOut: &paramSize,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if paramStatus == noErr, let paramPointer, paramSize > 0 {
                    annexBData.append(contentsOf: Self.startCode)
                    annexBData.append(Data(bytes: paramPointer, count: paramSize))
                }
            }
        }

        // Convert AVCC NAL units to Annex B
        var offset = 0
        while offset < totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            nalLength = nalLength.bigEndian
            offset += 4

            annexBData.append(contentsOf: Self.startCode)
            annexBData.append(Data(bytes: dataPointer + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }

        onEncodedData?(annexBData, isKeyframe)
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
