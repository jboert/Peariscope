package com.peariscope.host

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * Hardware-accelerated H.264 encoder using MediaCodec async callbacks.
 * Outputs Annex B NAL units suitable for streaming over Hyperswarm.
 *
 * Uses async callback mode instead of polling — frames are delivered
 * immediately when ready, eliminating the 10ms polling delay.
 */
class ScreenEncoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int = 60,
    private val bitrate: Int = 12_000_000
) {
    private var codec: MediaCodec? = null
    private var _inputSurface: Surface? = null
    private var callbackThread: HandlerThread? = null
    private var callbackHandler: Handler? = null
    @Volatile private var running = false

    /** Callback for encoded Annex B data. Called from encoder callback thread. */
    var onEncodedData: ((ByteArray, Boolean) -> Unit)? = null

    fun configure(): Surface {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // keyframe at least every 1 second
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)

            // CBR for consistent quality — no quality drops during busy frames
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)

            // High profile — better compression efficiency for screen content
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
            setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel4)

            // No B-frames — essential for low latency (B-frames add reorder delay)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)

            // Re-encode last frame when screen is static.
            // Without this, VirtualDisplay stops producing frames on unchanged screens
            // and viewers see a frozen image. Interval matches encoder fps.
            try {
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, (1_000_000L / fps).coerceAtLeast(33_333L))
            } catch (_: Exception) {}

            // Low latency hints
            setInteger(MediaFormat.KEY_LATENCY, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0)

            // SPS/PPS prepended to IDR — essential for stream join/recovery
            setInteger("prepend-sps-pps-to-idr-frames", 1)

            // Intra-refresh: spread keyframe cost across multiple frames
            // instead of one large IDR spike. Reduces per-frame size variance
            // and smooths out network bandwidth usage.
            try {
                setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, fps) // refresh over 1 second
            } catch (_: Exception) {}
        }

        // Create dedicated thread for encoder callbacks — avoids blocking main thread
        val thread = HandlerThread("ScreenEncoder-cb").apply { start() }
        callbackThread = thread
        callbackHandler = Handler(thread.looper)

        val mc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)

        // Async callback mode — zero-latency frame delivery
        mc.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                // Surface mode — input buffers not used
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (!running) {
                    try { codec.releaseOutputBuffer(index, false) } catch (_: Exception) {}
                    return
                }

                try {
                    if (info.size > 0) {
                        val outputBuffer = codec.getOutputBuffer(index) ?: return
                        val isKeyframe = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        val data = ByteArray(info.size)
                        outputBuffer.position(info.offset)
                        outputBuffer.limit(info.offset + info.size)
                        outputBuffer.get(data)

                        val annexB = ensureAnnexB(data, isKeyframe, codec)
                        onEncodedData?.invoke(annexB, isKeyframe)
                    }
                    codec.releaseOutputBuffer(index, false)
                } catch (e: Exception) {
                    if (running) Log.e(TAG, "Output buffer error", e)
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Encoder error: ${e.message}")
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.d(TAG, "Output format changed: $format")
            }
        }, callbackHandler)

        mc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        _inputSurface = mc.createInputSurface()
        codec = mc
        Log.d(TAG, "Encoder configured: ${width}x${height} @ ${bitrate/1000}kbps ${fps}fps (async)")
        return _inputSurface!!
    }

    fun start() {
        val mc = codec ?: return
        running = true
        mc.start()
        Log.d(TAG, "Encoder started (async callback mode)")
    }

    fun stop() {
        running = false
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping encoder", e)
        }
        _inputSurface?.release()
        _inputSurface = null
        codec = null
        callbackThread?.quitSafely()
        callbackThread = null
        callbackHandler = null
        Log.d(TAG, "Encoder stopped")
    }

    fun requestKeyframe() {
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec?.setParameters(params)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request keyframe", e)
        }
    }

    fun updateBitrate(newBitrate: Int) {
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrate)
            codec?.setParameters(params)
            Log.d(TAG, "Bitrate updated to ${newBitrate/1000}kbps")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update bitrate", e)
        }
    }

    private fun ensureAnnexB(data: ByteArray, isKeyframe: Boolean, mc: MediaCodec): ByteArray {
        if (data.size >= 4 && data[0] == 0.toByte() && data[1] == 0.toByte()) {
            if ((data[2] == 0.toByte() && data[3] == 1.toByte()) || data[2] == 1.toByte()) {
                if (isKeyframe) {
                    val nalType = if (data[2] == 1.toByte()) (data[3].toInt() and 0x1F) else (data[4].toInt() and 0x1F)
                    if (nalType == 5) {
                        val spsData = extractParameterSets(mc)
                        if (spsData != null) return spsData + data
                    }
                }
                return data
            }
        }
        return convertAvccToAnnexB(data)
    }

    private fun extractParameterSets(mc: MediaCodec): ByteArray? {
        val format = mc.outputFormat
        val sps = format.getByteBuffer("csd-0") ?: return null
        val pps = format.getByteBuffer("csd-1") ?: return null
        val spsBytes = ByteArray(sps.remaining()); sps.get(spsBytes); sps.rewind()
        val ppsBytes = ByteArray(pps.remaining()); pps.get(ppsBytes); pps.rewind()
        val sc = byteArrayOf(0, 0, 0, 1)
        return sc + spsBytes + sc + ppsBytes
    }

    private fun convertAvccToAnnexB(avcc: ByteArray): ByteArray {
        val sc = byteArrayOf(0, 0, 0, 1)
        val result = mutableListOf<Byte>()
        var offset = 0
        while (offset + 4 <= avcc.size) {
            val naluLen = ((avcc[offset].toInt() and 0xFF) shl 24) or
                          ((avcc[offset + 1].toInt() and 0xFF) shl 16) or
                          ((avcc[offset + 2].toInt() and 0xFF) shl 8) or
                          (avcc[offset + 3].toInt() and 0xFF)
            offset += 4
            if (naluLen <= 0 || offset + naluLen > avcc.size) break
            result.addAll(sc.toList())
            result.addAll(avcc.slice(offset until offset + naluLen))
            offset += naluLen
        }
        return if (result.isNotEmpty()) result.toByteArray() else avcc
    }

    companion object {
        private const val TAG = "ScreenEncoder"
    }
}
