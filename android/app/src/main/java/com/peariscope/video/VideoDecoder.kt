package com.peariscope.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Hardware-accelerated H.264/H.265 decoder using MediaCodec.
 * Takes Annex B NAL units from the network and decodes to a Surface.
 */
class VideoDecoder {
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var isH265 = false
    private var isStarted = false

    // H.264 parameter sets
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null

    // H.265 parameter sets
    private var vps: ByteArray? = null
    private var h265Sps: ByteArray? = null
    private var h265Pps: ByteArray? = null

    // Rate limiting — same pattern as iOS
    private val pendingLock = ReentrantLock()
    private var queuedBlocks = 0
    private var lastAcceptTime = 0L
    private var decodeCount = 0
    private var dropCount = 0
    private var hasReceivedKeyframe = false
    private var presentationTimeUs = 0L

    // Corruption detection
    private var consecutiveDecodeErrors = 0
    private var lastIdrRequestTime = 0L

    var onFirstFrame: (() -> Unit)? = null
    var onFormatChanged: ((Int, Int) -> Unit)? = null
    var onRequestIdr: (() -> Unit)? = null
    var onLog: ((String) -> Unit)? = null

    fun configure(surface: Surface) {
        this.surface = surface
    }

    /**
     * Feed Annex B formatted video data from the network.
     * Thread-safe — can be called from IPC thread.
     */
    fun decode(annexBData: ByteArray) {
        // Time gate + queue depth check under lock
        pendingLock.withLock {
            val now = System.nanoTime()
            if (now - lastAcceptTime < MIN_ACCEPT_INTERVAL_NS) {
                dropCount++
                return
            }
            lastAcceptTime = now
            if (queuedBlocks >= MAX_QUEUED_BLOCKS) {
                dropCount++
                return
            }
            queuedBlocks++
        }

        try {
            decodeInternal(annexBData)
        } finally {
            pendingLock.withLock { queuedBlocks-- }
        }
    }

    private fun decodeInternal(annexBData: ByteArray) {
        val nalUnits = parseAnnexB(annexBData)

        for (nal in nalUnits) {
            if (nal.isEmpty()) continue

            val nalType264 = nal[0].toInt() and 0x1F
            val nalType265 = (nal[0].toInt() shr 1) and 0x3F

            if (decodeCount == 0 && !isStarted) {
                Log.d(TAG, "NAL byte=0x${String.format("%02x", nal[0])} h264type=$nalType264 h265type=$nalType265 isH265=$isH265 size=${nal.size}")
            }

            // Try H.265 first (VPS/SPS/PPS have higher NAL type values)
            if (!isStarted) {
                when (nalType265) {
                    32 -> { // VPS
                        vps = nal
                        isH265 = true
                        continue
                    }
                    33 -> { // SPS
                        h265Sps = nal
                        isH265 = true
                        continue
                    }
                    34 -> { // PPS
                        h265Pps = nal
                        isH265 = true
                        if (vps != null && h265Sps != null) {
                            configureCodec()
                        }
                        continue
                    }
                }
            }

            if (isH265) {
                when (nalType265) {
                    32 -> { vps = nal; continue }
                    33 -> { h265Sps = nal; continue }
                    34 -> {
                        h265Pps = nal
                        if (vps != null && h265Sps != null && !isStarted) {
                            configureCodec()
                        }
                        continue
                    }
                    in 16..21 -> { // IDR
                        hasReceivedKeyframe = true
                        consecutiveDecodeErrors = 0
                        decodeNAL(nal)
                    }
                    in 0..9 -> { // non-IDR
                        if (hasReceivedKeyframe) {
                            decodeNAL(nal)
                        } else {
                            maybeRequestIdr()
                        }
                    }
                }
            } else {
                when (nalType264) {
                    7 -> { // SPS
                        sps = nal
                        continue
                    }
                    8 -> { // PPS
                        pps = nal
                        if (sps != null && !isStarted) {
                            configureCodec()
                        }
                        continue
                    }
                    5 -> { // IDR
                        hasReceivedKeyframe = true
                        consecutiveDecodeErrors = 0
                        decodeNAL(nal)
                    }
                    1 -> { // Non-IDR
                        if (hasReceivedKeyframe) {
                            decodeNAL(nal)
                        } else {
                            maybeRequestIdr()
                        }
                    }
                }
            }
        }
    }

    /** Request IDR if we haven't received a keyframe and haven't asked recently */
    private fun maybeRequestIdr() {
        val now = System.currentTimeMillis()
        if (now - lastIdrRequestTime > 1000) {
            lastIdrRequestTime = now
            onRequestIdr?.invoke()
        }
    }

    private fun configureCodec() {
        val s = surface ?: return

        val mime: String
        val csd0: ByteArray
        val csd1: ByteArray?

        // Parse actual resolution from SPS
        var width = 1920
        var height = 1080

        if (isH265) {
            mime = MediaFormat.MIMETYPE_VIDEO_HEVC
            val startCode = byteArrayOf(0, 0, 0, 1)
            val vpsData = vps ?: return
            val spsData = h265Sps ?: return
            val ppsData = h265Pps ?: return
            csd0 = startCode + vpsData + startCode + spsData + startCode + ppsData
            csd1 = null

            // Let MediaCodec determine resolution from CSD via OUTPUT_FORMAT_CHANGED.
        } else {
            mime = MediaFormat.MIMETYPE_VIDEO_AVC
            val spsData = sps ?: return
            val ppsData = pps ?: return
            val startCode = byteArrayOf(0, 0, 0, 1)
            csd0 = startCode + spsData
            csd1 = startCode + ppsData

            // Parse H.264 SPS for actual resolution
            val parsed = parseSpsResolution(spsData)
            if (parsed != null && parsed.first >= 128 && parsed.second >= 128) {
                width = parsed.first
                height = parsed.second
                Log.d(TAG, "Parsed SPS resolution: ${width}x${height}")
            } else if (parsed != null) {
                Log.d(TAG, "Ignoring tiny SPS resolution: ${parsed.first}x${parsed.second}")
            }
        }

        try {
            codec?.let {
                try { it.stop() } catch (_: Exception) {}
                it.release()
            }

            val format = MediaFormat.createVideoFormat(mime, width, height)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(csd0))
            if (csd1 != null) {
                format.setByteBuffer("csd-1", ByteBuffer.wrap(csd1))
            }
            // Low latency mode
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)

            // Find hardware decoder
            val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val codecName = codecList.findDecoderForFormat(format)

            val mc = if (codecName != null) {
                MediaCodec.createByCodecName(codecName)
            } else {
                MediaCodec.createDecoderByType(mime)
            }

            mc.configure(format, s, null, 0)
            mc.start()
            codec = mc
            isStarted = true
            Log.d(TAG, "MediaCodec configured: $mime ${width}x${height} (${codecName ?: "default"})")

            // Don't report resolution here — wait for OUTPUT_FORMAT_CHANGED
            // which has the actual decoded dimensions from the stream.
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure MediaCodec", e)
            isStarted = false
        }
    }

    private fun decodeNAL(nalData: ByteArray) {
        val mc = codec ?: return

        try {
            val inputIdx = mc.dequeueInputBuffer(1000)
            if (inputIdx < 0) {
                drainOutput(mc)
                return
            }

            val inputBuffer = mc.getInputBuffer(inputIdx) ?: return
            val startCode = byteArrayOf(0, 0, 0, 1)
            inputBuffer.clear()
            inputBuffer.put(startCode)
            inputBuffer.put(nalData)

            presentationTimeUs += 16_667
            mc.queueInputBuffer(inputIdx, 0, startCode.size + nalData.size, presentationTimeUs, 0)

            drainOutput(mc)
        } catch (e: MediaCodec.CodecException) {
            Log.e(TAG, "Decode codec error: ${e.diagnosticInfo}", e)
            consecutiveDecodeErrors++
            if (consecutiveDecodeErrors >= 3) {
                maybeRequestIdr()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Decode error", e)
            consecutiveDecodeErrors++
            if (consecutiveDecodeErrors >= 3) {
                maybeRequestIdr()
            }
        }
    }

    private fun drainOutput(mc: MediaCodec) {
        val bufferInfo = MediaCodec.BufferInfo()
        while (true) {
            val outputIdx = mc.dequeueOutputBuffer(bufferInfo, 0)
            if (outputIdx >= 0) {
                // Only render to surface after first keyframe decoded.
                // Before that, buffers may contain uninitialized (green) data.
                if (hasReceivedKeyframe && (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    mc.releaseOutputBuffer(outputIdx, System.nanoTime())
                    decodeCount++
                    consecutiveDecodeErrors = 0
                    if (decodeCount == 1) {
                        onFirstFrame?.invoke()
                    }
                } else {
                    mc.releaseOutputBuffer(outputIdx, false)
                }
            } else if (outputIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val newFormat = mc.outputFormat
                Log.d(TAG, "Output format changed: $newFormat")
                val w = newFormat.getInteger(MediaFormat.KEY_WIDTH, 0)
                val h = newFormat.getInteger(MediaFormat.KEY_HEIGHT, 0)
                val cropRight = if (newFormat.containsKey("crop-right")) newFormat.getInteger("crop-right") + 1 else w
                val cropBottom = if (newFormat.containsKey("crop-bottom")) newFormat.getInteger("crop-bottom") + 1 else h
                // Ignore tiny dimensions from codec initialization artifacts
                if (cropRight >= 128 && cropBottom >= 128) {
                    onFormatChanged?.invoke(cropRight, cropBottom)
                }
            } else {
                break
            }
        }
    }

    fun stop() {
        isStarted = false
        try {
            codec?.stop()
            codec?.release()
        } catch (_: Exception) {}
        codec = null
        sps = null
        pps = null
        vps = null
        h265Sps = null
        h265Pps = null
        decodeCount = 0
        hasReceivedKeyframe = false
        presentationTimeUs = 0L
        consecutiveDecodeErrors = 0
    }

    fun diagnosticSummary(): String {
        return "decoded=$decodeCount drops=$dropCount isH265=$isH265 started=$isStarted"
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val MAX_QUEUED_BLOCKS = 2
        private val MIN_ACCEPT_INTERVAL_NS = 1_000_000_000L / 61

        /**
         * Parse H.264 SPS NAL unit to extract resolution.
         * Handles profile_idc, chroma, cropping.
         */
        fun parseSpsResolution(spsNal: ByteArray): Pair<Int, Int>? {
            try {
                val reader = BitReader(spsNal)
                val profileIdc = reader.readBits(8)
                reader.skipBits(16) // constraint flags + level
                reader.readUE() // seq_parameter_set_id

                if (profileIdc in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134)) {
                    val chromaFormatIdc = reader.readUE()
                    if (chromaFormatIdc == 3) reader.skipBits(1) // separate_colour_plane_flag
                    reader.readUE() // bit_depth_luma_minus8
                    reader.readUE() // bit_depth_chroma_minus8
                    reader.skipBits(1) // qpprime_y_zero_transform_bypass_flag
                    val seqScalingMatrixPresent = reader.readBit()
                    if (seqScalingMatrixPresent == 1) {
                        val count = if (chromaFormatIdc != 3) 8 else 12
                        for (i in 0 until count) {
                            if (reader.readBit() == 1) { // scaling_list_present
                                val size = if (i < 6) 16 else 64
                                var lastScale = 8
                                var nextScale = 8
                                for (j in 0 until size) {
                                    if (nextScale != 0) {
                                        val delta = reader.readSE()
                                        nextScale = (lastScale + delta + 256) % 256
                                    }
                                    lastScale = if (nextScale == 0) lastScale else nextScale
                                }
                            }
                        }
                    }
                }

                reader.readUE() // log2_max_frame_num_minus4
                val picOrderCntType = reader.readUE()
                when (picOrderCntType) {
                    0 -> reader.readUE() // log2_max_pic_order_cnt_lsb_minus4
                    1 -> {
                        reader.skipBits(1) // delta_pic_order_always_zero_flag
                        reader.readSE() // offset_for_non_ref_pic
                        reader.readSE() // offset_for_top_to_bottom_field
                        val numRefFrames = reader.readUE()
                        for (i in 0 until numRefFrames) reader.readSE()
                    }
                }

                reader.readUE() // max_num_ref_frames
                reader.skipBits(1) // gaps_in_frame_num_value_allowed_flag

                val picWidthInMbs = reader.readUE() + 1
                val picHeightInMapUnits = reader.readUE() + 1
                val frameMbsOnly = reader.readBit()
                if (frameMbsOnly == 0) reader.skipBits(1) // mb_adaptive_frame_field_flag
                reader.skipBits(1) // direct_8x8_inference_flag

                var width = picWidthInMbs * 16
                var height = (2 - frameMbsOnly) * picHeightInMapUnits * 16

                val frameCropping = reader.readBit()
                if (frameCropping == 1) {
                    val cropLeft = reader.readUE()
                    val cropRight = reader.readUE()
                    val cropTop = reader.readUE()
                    val cropBottom = reader.readUE()
                    width -= (cropLeft + cropRight) * 2
                    height -= (cropTop + cropBottom) * 2
                }

                if (width > 0 && height > 0) {
                    return Pair(width, height)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to parse SPS", e)
            }
            return null
        }

        /**
         * Parse H.265 SPS NAL unit to extract resolution.
         * H.265 SPS starts with 2-byte NAL header, then:
         * sps_video_parameter_set_id(4), sps_max_sub_layers_minus1(3),
         * temporal_id_nesting_flag(1), profile_tier_level(...),
         * sps_seq_parameter_set_id(ue), chroma_format_idc(ue),
         * [if chroma==3: separate_colour_plane_flag(1)],
         * pic_width_in_luma_samples(ue), pic_height_in_luma_samples(ue)
         */
        fun parseH265SpsResolution(spsNal: ByteArray): Pair<Int, Int>? {
            if (spsNal.size < 4) return null
            try {
                // Skip 2-byte NAL header
                val reader = BitReader(spsNal.copyOfRange(2, spsNal.size))

                reader.skipBits(4) // sps_video_parameter_set_id
                val maxSubLayers = reader.readBits(3) // sps_max_sub_layers_minus1
                reader.skipBits(1) // temporal_id_nesting_flag

                // profile_tier_level(1, maxSubLayers)
                // general_profile_space(2), general_tier_flag(1), general_profile_idc(5)
                reader.skipBits(8)
                // general_profile_compatibility_flags(32)
                reader.skipBits(32)
                // general_constraint_indicator_flags(48)
                reader.skipBits(48)
                // general_level_idc(8)
                reader.skipBits(8)

                // sub_layer flags (if maxSubLayers > 0)
                if (maxSubLayers > 0) {
                    val subLayerProfilePresent = BooleanArray(maxSubLayers)
                    val subLayerLevelPresent = BooleanArray(maxSubLayers)
                    for (i in 0 until maxSubLayers) {
                        subLayerProfilePresent[i] = reader.readBit() == 1
                        subLayerLevelPresent[i] = reader.readBit() == 1
                    }
                    // Padding to byte alignment for remaining sub-layer bits
                    if (maxSubLayers < 8) {
                        reader.skipBits((8 - maxSubLayers) * 2)
                    }
                    for (i in 0 until maxSubLayers) {
                        if (subLayerProfilePresent[i]) {
                            reader.skipBits(88) // sub_layer profile (2+1+5+32+48)
                        }
                        if (subLayerLevelPresent[i]) {
                            reader.skipBits(8) // sub_layer_level_idc
                        }
                    }
                }

                reader.readUE() // sps_seq_parameter_set_id
                val chromaFormatIdc = reader.readUE()
                if (chromaFormatIdc == 3) reader.skipBits(1) // separate_colour_plane_flag

                val width = reader.readUE() // pic_width_in_luma_samples
                val height = reader.readUE() // pic_height_in_luma_samples

                if (width > 0 && height > 0) {
                    // Check for conformance cropping
                    val conformanceWindowFlag = reader.readBit()
                    if (conformanceWindowFlag == 1) {
                        val cropLeft = reader.readUE()
                        val cropRight = reader.readUE()
                        val cropTop = reader.readUE()
                        val cropBottom = reader.readUE()
                        val subWidthC = if (chromaFormatIdc == 1 || chromaFormatIdc == 2) 2 else 1
                        val subHeightC = if (chromaFormatIdc == 1) 2 else 1
                        val croppedWidth = width - (cropLeft + cropRight) * subWidthC
                        val croppedHeight = height - (cropTop + cropBottom) * subHeightC
                        return Pair(croppedWidth, croppedHeight)
                    }
                    return Pair(width, height)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to parse H.265 SPS", e)
            }
            return null
        }

        fun parseAnnexB(data: ByteArray): List<ByteArray> {
            val nalUnits = mutableListOf<ByteArray>()
            val count = data.size
            var i = 0

            while (i < count) {
                var startCodeLen = 0
                if (i + 3 < count && data[i] == 0.toByte() && data[i + 1] == 0.toByte()
                    && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    startCodeLen = 4
                } else if (i + 2 < count && data[i] == 0.toByte() && data[i + 1] == 0.toByte()
                    && data[i + 2] == 1.toByte()) {
                    startCodeLen = 3
                }

                if (startCodeLen > 0) {
                    val nalStart = i + startCodeLen
                    var nalEnd = count
                    var j = nalStart
                    while (j < count) {
                        if (j + 3 < count && data[j] == 0.toByte() && data[j + 1] == 0.toByte()
                            && data[j + 2] == 0.toByte() && data[j + 3] == 1.toByte()) {
                            nalEnd = j; break
                        }
                        if (j + 2 < count && data[j] == 0.toByte() && data[j + 1] == 0.toByte()
                            && data[j + 2] == 1.toByte()) {
                            nalEnd = j; break
                        }
                        j++
                    }
                    if (nalEnd > nalStart) {
                        nalUnits.add(data.copyOfRange(nalStart, nalEnd))
                    }
                    i = nalEnd
                } else {
                    i++
                }
            }
            return nalUnits
        }
    }

    /**
     * Exp-Golomb / bit reader for H.264 SPS parsing.
     */
    private class BitReader(private val data: ByteArray) {
        private var byteOffset = 0
        private var bitOffset = 0

        fun readBit(): Int {
            if (byteOffset >= data.size) return 0
            val bit = (data[byteOffset].toInt() shr (7 - bitOffset)) and 1
            bitOffset++
            if (bitOffset == 8) { bitOffset = 0; byteOffset++ }
            return bit
        }

        fun readBits(n: Int): Int {
            var value = 0
            for (i in 0 until n) {
                value = (value shl 1) or readBit()
            }
            return value
        }

        fun skipBits(n: Int) {
            for (i in 0 until n) readBit()
        }

        /** Unsigned Exp-Golomb */
        fun readUE(): Int {
            var leadingZeros = 0
            while (readBit() == 0 && leadingZeros < 31) leadingZeros++
            if (leadingZeros == 0) return 0
            return (1 shl leadingZeros) - 1 + readBits(leadingZeros)
        }

        /** Signed Exp-Golomb */
        fun readSE(): Int {
            val code = readUE()
            return if (code % 2 == 0) -(code / 2) else (code + 1) / 2
        }
    }
}
