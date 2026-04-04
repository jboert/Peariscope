package com.peariscope.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Decodes AAC audio and plays it in real-time using MediaCodec + AudioTrack.
 * Thread-safe: audio data can be fed from any thread.
 */
class AudioPlayer(
    private val sampleRate: Int = 48000,
    private val channels: Int = 2
) {
    private var codec: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var isRunning = false
    private val lock = ReentrantLock()
    private var bufferedPackets = 0

    fun start() {
        lock.withLock {
            if (isRunning) return

            try {
                // Configure AAC decoder
                val format = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC,
                    sampleRate,
                    channels
                )
                // AAC-LC profile
                format.setInteger(MediaFormat.KEY_AAC_PROFILE, 2)
                format.setInteger(MediaFormat.KEY_IS_ADTS, 0)

                // ESDS / AudioSpecificConfig for 48kHz stereo AAC-LC
                // Profile=2(AAC-LC), SamplingFreqIdx=3(48000), ChannelConfig=2(stereo)
                val csd0 = byteArrayOf(0x11, 0x90.toByte())
                format.setByteBuffer("csd-0", ByteBuffer.wrap(csd0))

                val mc = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                mc.configure(format, null, null, 0)
                mc.start()
                codec = mc

                // Configure AudioTrack
                val channelConfig = if (channels == 2)
                    AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
                val bufferSize = AudioTrack.getMinBufferSize(
                    sampleRate,
                    channelConfig,
                    AudioFormat.ENCODING_PCM_16BIT
                )

                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelConfig)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize * 2)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                track.play()
                audioTrack = track
                isRunning = true
                bufferedPackets = 0

                Log.d(TAG, "AudioPlayer started: ${sampleRate}Hz ${channels}ch")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start AudioPlayer", e)
            }
        }
    }

    /**
     * Feed encoded AAC data received from the network.
     * Can be called from any thread.
     */
    fun decodeAndPlay(aacData: ByteArray) {
        val mc: MediaCodec
        val track: AudioTrack
        lock.withLock {
            if (!isRunning) return
            mc = codec ?: return
            track = audioTrack ?: return
        }

        try {
            // Queue input
            val inputIdx = mc.dequeueInputBuffer(1000) // 1ms timeout
            if (inputIdx < 0) return

            val inputBuffer = mc.getInputBuffer(inputIdx) ?: return
            inputBuffer.clear()
            inputBuffer.put(aacData)
            mc.queueInputBuffer(inputIdx, 0, aacData.size, 0, 0)

            // Drain output
            val bufferInfo = MediaCodec.BufferInfo()
            while (true) {
                val outputIdx = mc.dequeueOutputBuffer(bufferInfo, 0)
                if (outputIdx >= 0) {
                    val outputBuffer = mc.getOutputBuffer(outputIdx) ?: break
                    val pcmData = ByteArray(bufferInfo.size)
                    outputBuffer.position(bufferInfo.offset)
                    outputBuffer.get(pcmData)
                    mc.releaseOutputBuffer(outputIdx, false)

                    lock.withLock { bufferedPackets++ }
                    val shouldPlay = lock.withLock { bufferedPackets >= JITTER_BUFFER_SIZE }

                    if (shouldPlay) {
                        track.write(pcmData, 0, pcmData.size)
                    }
                } else {
                    break
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Audio decode error", e)
        }
    }

    fun stop() {
        lock.withLock {
            isRunning = false
            try {
                codec?.stop()
                codec?.release()
            } catch (_: Exception) {}
            codec = null

            try {
                audioTrack?.stop()
                audioTrack?.release()
            } catch (_: Exception) {}
            audioTrack = null
            bufferedPackets = 0
        }
    }

    companion object {
        private const val TAG = "AudioPlayer"
        private const val JITTER_BUFFER_SIZE = 3 // ~60ms at 1024 frames/48kHz
    }
}
