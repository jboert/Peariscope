import Foundation
import AVFoundation
import AudioToolbox

/// Decodes AAC audio and plays it in real-time using AVAudioEngine.
/// Thread-safe: audio data can be fed from any thread.
public final class AudioPlayer: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var converter: AudioConverterRef?
    private let lock = NSLock()

    private let sampleRate: Double
    private let channels: UInt32
    private var outputFormat: AVAudioFormat?
    private var isRunning = false

    /// Jitter buffer: accumulate a few packets before starting playback
    private var bufferedPackets = 0
    private static let jitterBufferSize = 3  // ~60ms at 1024 frames/48kHz

    public init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        // NOTE: AVAudioSession is configured once at app launch (PeariscopeAppDelegate).
        // Do NOT call setCategory/setActive here — it deadlocks the main thread when
        // the audio session is contested (e.g., after a previous viewer session).

        // Create AAC decoder
        var inputDesc = AudioStreamBasicDescription(
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

        var outputDesc = AudioStreamBasicDescription(
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

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inputDesc, &outputDesc, &conv)
        guard status == noErr, let conv else {
            throw AudioPlayerError.decoderCreationFailed(status)
        }
        converter = conv

        // Set up AVAudioEngine
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!
        outputFormat = format

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Connect with the PCM format
        let mixerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)

        try engine.start()
        player.play()

        self.engine = engine
        self.playerNode = player
        self.isRunning = true
        self.bufferedPackets = 0
    }

    /// Feed encoded AAC data received from the network.
    /// Can be called from any thread.
    public func decodeAndPlay(aacData: Data) {
        lock.lock()
        guard isRunning, let converter, let playerNode, let outputFormat else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Decode AAC to PCM
        let framesPerPacket: UInt32 = 1024
        let pcmBufferSize = Int(framesPerPacket * channels * 4)  // float32
        let pcmData = UnsafeMutablePointer<UInt8>.allocate(capacity: pcmBufferSize)
        defer { pcmData.deallocate() }

        var outputBuffer = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(pcmBufferSize),
            mData: UnsafeMutableRawPointer(pcmData)
        )
        var outputBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: outputBuffer)

        var packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(aacData.count)
        )

        var outputPacketCount = framesPerPacket

        let aacCopy = aacData
        var inputConsumed = false

        let status = aacCopy.withUnsafeBytes { rawBuf -> OSStatus in
            var userData = DecoderInputData(
                data: UnsafeMutableRawPointer(mutating: rawBuf.baseAddress!),
                dataSize: UInt32(aacCopy.count),
                packetDesc: packetDesc,
                consumed: false
            )

            return AudioConverterFillComplexBuffer(
                converter,
                { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                    guard let userData = inUserData?.assumingMemoryBound(to: DecoderInputData.self) else {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }
                    if userData.pointee.consumed {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mNumberChannels = 2
                    ioData.pointee.mBuffers.mDataByteSize = userData.pointee.dataSize
                    ioData.pointee.mBuffers.mData = userData.pointee.data
                    ioNumberDataPackets.pointee = 1
                    if let desc = outDataPacketDescription {
                        desc.pointee = withUnsafeMutablePointer(to: &userData.pointee.packetDesc) { $0 }
                    }
                    userData.pointee.consumed = true
                    return noErr
                },
                &userData,
                &outputPacketCount,
                &outputBufferList,
                nil
            )
        }

        guard status == noErr, outputPacketCount > 0 else { return }

        let decodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
        guard decodedSize > 0 else { return }

        // Convert interleaved PCM to non-interleaved AVAudioPCMBuffer for the player
        let deinterleavedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: deinterleavedFormat,
            frameCapacity: framesPerPacket
        ) else { return }

        pcmBuffer.frameLength = outputPacketCount

        // Deinterleave: interleaved [L R L R ...] → separate [L L L ...] [R R R ...]
        let srcPtr = pcmData.withMemoryRebound(to: Float.self, capacity: Int(outputPacketCount * channels)) { $0 }
        for ch in 0..<Int(channels) {
            guard let chData = pcmBuffer.floatChannelData?[ch] else { continue }
            for frame in 0..<Int(outputPacketCount) {
                chData[frame] = srcPtr[frame * Int(channels) + ch]
            }
        }

        lock.lock()
        bufferedPackets += 1
        let shouldSchedule = bufferedPackets >= Self.jitterBufferSize || bufferedPackets > 1
        lock.unlock()

        if shouldSchedule {
            playerNode.scheduleBuffer(pcmBuffer)
        } else {
            // Buffer initial packets for jitter resistance
            playerNode.scheduleBuffer(pcmBuffer)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        isRunning = false
        playerNode?.stop()
        engine?.stop()

        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }

        playerNode = nil
        engine = nil
        outputFormat = nil
        bufferedPackets = 0
    }

    deinit {
        stop()
    }
}

private struct DecoderInputData {
    var data: UnsafeMutableRawPointer
    var dataSize: UInt32
    var packetDesc: AudioStreamPacketDescription
    var consumed: Bool
}

public enum AudioPlayerError: Error {
    case decoderCreationFailed(OSStatus)
}
