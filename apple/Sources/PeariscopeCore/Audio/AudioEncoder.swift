import Foundation
import AVFoundation
import AudioToolbox

/// Encodes PCM audio to AAC using AudioToolbox for low-latency streaming.
/// Thread-safe: can be called from ScreenCaptureKit's audio callback thread.
public final class AudioEncoder: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private let queue = DispatchQueue(label: "peariscope.audio.encoder", qos: .userInteractive)

    /// Called with encoded AAC data ready to send over the network.
    public var onEncodedData: ((Data) -> Void)?

    private let sampleRate: Double
    private let channels: UInt32

    public init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public func start() throws {
        var inputDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputDesc, &outputDesc, &converter)
        guard status == noErr, let converter else {
            throw AudioEncoderError.converterCreationFailed(status)
        }
        self.converter = converter

        // Set bitrate — 128kbps stereo is good quality for streaming
        var bitrate: UInt32 = 128_000
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )
    }

    /// Encode a CMSampleBuffer containing PCM audio from ScreenCaptureKit.
    public func encode(sampleBuffer: CMSampleBuffer) {
        guard let converter else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        guard let asbd = formatDesc.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { return }

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard let dataPointer, dataLength > 0 else { return }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = dataLength / bytesPerFrame

        // AAC encodes 1024 frames per packet
        let framesPerPacket = 1024
        var offset = 0

        while offset + framesPerPacket * bytesPerFrame <= dataLength {
            let inputData = UnsafeMutableRawPointer(dataPointer + offset)
            let inputSize = framesPerPacket * bytesPerFrame

            var inputBuffer = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(inputSize),
                mData: inputData
            )
            var inputBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: inputBuffer)

            // Output buffer — AAC is much smaller than PCM
            let outputBufferSize = 2048
            let outputData = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
            defer { outputData.deallocate() }

            var outputBuffer = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(outputBufferSize),
                mData: UnsafeMutableRawPointer(outputData)
            )
            var outputBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: outputBuffer)

            var packetDesc = AudioStreamPacketDescription()
            var outputPacketCount: UInt32 = 1

            var userData = InputUserData(buffer: &inputBufferList, consumed: false)

            let status = AudioConverterFillComplexBuffer(
                converter,
                { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                    guard let userData = inUserData?.assumingMemoryBound(to: InputUserData.self).pointee else {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }
                    if userData.consumed {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }
                    let src = userData.buffer.pointee.mBuffers
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mNumberChannels = src.mNumberChannels
                    ioData.pointee.mBuffers.mDataByteSize = src.mDataByteSize
                    ioData.pointee.mBuffers.mData = src.mData
                    ioNumberDataPackets.pointee = 1024
                    // Mark consumed
                    inUserData?.assumingMemoryBound(to: InputUserData.self).pointee.consumed = true
                    return noErr
                },
                &userData,
                &outputPacketCount,
                &outputBufferList,
                &packetDesc
            )

            if status == noErr && outputPacketCount > 0 {
                let encodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
                if encodedSize > 0 {
                    let encoded = Data(bytes: outputData, count: encodedSize)
                    onEncodedData?(encoded)
                }
            }

            offset += framesPerPacket * bytesPerFrame
        }
    }

    public func stop() {
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
        onEncodedData = nil
    }

    deinit {
        stop()
    }
}

private struct InputUserData {
    var buffer: UnsafeMutablePointer<AudioBufferList>
    var consumed: Bool
}

public enum AudioEncoderError: Error {
    case converterCreationFailed(OSStatus)
}
