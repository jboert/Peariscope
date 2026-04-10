#include "FfmpegDecoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
}

#include <iostream>
#include <cstring>

namespace peariscope {

FfmpegDecoder::FfmpegDecoder() = default;
FfmpegDecoder::~FfmpegDecoder() { Shutdown(); }

bool FfmpegDecoder::Initialize(uint32_t width, uint32_t height, CodecType codec) {
    initWidth_ = width;
    initHeight_ = height;

    if (codec == CodecType::Unknown) {
        // Defer actual codec init until first packet (auto-detect)
        std::cerr << "[FfmpegDecoder] Deferred init: " << width << "x" << height
                  << " (will auto-detect codec)" << std::endl;
        return true;
    }

    return InitCodec(width, height, codec);
}

bool FfmpegDecoder::InitCodec(uint32_t width, uint32_t height, CodecType codec) {
    // Shut down any existing context
    if (ctx_) {
        Shutdown();
    }

    AVCodecID codecId = (codec == CodecType::H265)
        ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;

    const AVCodec* avcodec = avcodec_find_decoder(codecId);
    if (!avcodec) {
        std::cerr << "[FfmpegDecoder] No "
                  << (codec == CodecType::H265 ? "H.265" : "H.264")
                  << " decoder found" << std::endl;
        return false;
    }

    ctx_ = avcodec_alloc_context3(avcodec);
    if (!ctx_) {
        std::cerr << "[FfmpegDecoder] Failed to allocate codec context" << std::endl;
        return false;
    }

    ctx_->width = static_cast<int>(width);
    ctx_->height = static_cast<int>(height);

    // Low-latency decoding flags
    ctx_->flags |= AV_CODEC_FLAG_LOW_DELAY;
    ctx_->flags2 |= AV_CODEC_FLAG2_FAST;

    // Allow the decoder to use multiple threads for speed
    ctx_->thread_count = 1; // single thread for lowest latency

    int ret = avcodec_open2(ctx_, avcodec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        std::cerr << "[FfmpegDecoder] avcodec_open2 failed: " << errbuf << std::endl;
        avcodec_free_context(&ctx_);
        return false;
    }

    frame_ = av_frame_alloc();
    if (!frame_) {
        std::cerr << "[FfmpegDecoder] Failed to allocate frame" << std::endl;
        avcodec_free_context(&ctx_);
        return false;
    }

    decodeCount_ = 0;
    detectedCodec_ = codec;

    std::cerr << "[FfmpegDecoder] Initialized: " << width << "x" << height
              << " codec=" << avcodec->name
              << (codec == CodecType::H265 ? " (H.265)" : " (H.264)")
              << std::endl;

    return true;
}

FfmpegDecoder::CodecType FfmpegDecoder::DetectCodec(const uint8_t* data, size_t size) {
    // Scan ALL NAL units in the packet to find distinguishing types.
    // H.265 streams always contain VPS (type 32, NAL byte 0x40/0x41).
    // H.264 SPS (type 7, NAL byte 0x27/0x67) can be falsely parsed as H.265 IDR (type 19),
    // so we must check for H.265-specific NAL types (VPS) rather than relying on IDR detection.
    bool foundH265Vps = false;
    bool foundH264Sps = false;

    for (size_t i = 0; i + 5 < size; i++) {
        int scLen = 0;
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) scLen = 4;
        else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) scLen = 3;
        if (scLen == 0) continue;

        uint8_t nalByte = data[i + scLen];
        if (nalByte & 0x80) { i += scLen; continue; } // forbidden_zero_bit set

        uint8_t h264type = nalByte & 0x1F;
        uint8_t h265type = (nalByte >> 1) & 0x3F;

        // H.265 VPS (type 32) — NAL byte is 0x40 or 0x41. This is unambiguous:
        // In H.264, byte 0x40 = type 0 (unspecified) with nal_ref_idc=2, which is never used.
        if (h265type == 32) {
            foundH265Vps = true;
            break; // Definitive
        }

        // H.264 SPS (type 7): verify by checking profile_idc in next byte
        // Valid H.264 profiles: 66(Baseline), 77(Main), 88(Extended), 100(High),
        // 110(High10), 122(High422), 244(High444), 44(CAVLC444)
        if (h264type == 7 && (i + scLen + 1) < size) {
            uint8_t profileIdc = data[i + scLen + 1];
            if (profileIdc == 66 || profileIdc == 77 || profileIdc == 88 ||
                profileIdc == 100 || profileIdc == 110 || profileIdc == 122 ||
                profileIdc == 244 || profileIdc == 44) {
                foundH264Sps = true;
            }
        }

        i += scLen; // advance past start code
    }

    if (foundH265Vps) {
        std::cerr << "[FfmpegDecoder] Detected H.265 (found VPS NAL)" << std::endl;
        return CodecType::H265;
    }
    if (foundH264Sps) {
        std::cerr << "[FfmpegDecoder] Detected H.264 (found SPS with valid profile)" << std::endl;
        return CodecType::H264;
    }

    std::cerr << "[FfmpegDecoder] Could not detect codec from packet" << std::endl;
    return CodecType::Unknown;
}

bool FfmpegDecoder::Decode(const uint8_t* data, size_t size) {
    // Auto-detect and initialize codec on first packet
    if (!ctx_) {
        CodecType detected = DetectCodec(data, size);
        if (detected == CodecType::Unknown) {
            // Can't detect yet, skip
            return false;
        }
        if (!InitCodec(initWidth_, initHeight_, detected)) {
            return false;
        }
    }

    if (!ctx_ || !frame_) return false;

    AVPacket* pkt = av_packet_alloc();
    if (!pkt) return false;

    pkt->data = const_cast<uint8_t*>(data);
    pkt->size = static_cast<int>(size);

    int ret = avcodec_send_packet(ctx_, pkt);
    if (decodeCount_ < 20) {
        std::cerr << "[FfmpegDecoder] send_packet ret=" << ret
                  << " size=" << pkt->size << " count=" << decodeCount_ << std::endl;
    }
    if (ret < 0) {
        if (decodeCount_ < 20) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            std::cerr << "[FfmpegDecoder] avcodec_send_packet failed: " << errbuf << std::endl;
        }
        av_packet_free(&pkt);
        return false;
    }

    av_packet_free(&pkt);
    decodeCount_++;

    // Drain all available decoded frames
    int framesDecoded = 0;
    while (true) {
        ret = avcodec_receive_frame(ctx_, frame_);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            if (decodeCount_ < 20) {
                char errbuf[256];
                av_strerror(ret, errbuf, sizeof(errbuf));
                std::cerr << "[FfmpegDecoder] avcodec_receive_frame failed: " << errbuf << std::endl;
            }
            return false;
        }

        framesDecoded++;
        // Deliver decoded frame via callback
        if (callback_) {
            uint64_t timestamp = (frame_->pts != AV_NOPTS_VALUE)
                ? static_cast<uint64_t>(frame_->pts) : 0;
            if (decodeCount_ < 20) {
                std::cerr << "[FfmpegDecoder] Frame decoded: " << frame_->width << "x"
                          << frame_->height << " fmt=" << frame_->format << std::endl;
            }
            callback_(frame_, timestamp);
        } else if (decodeCount_ < 20) {
            std::cerr << "[FfmpegDecoder] Frame decoded but NO callback set!" << std::endl;
        }
    }
    if (decodeCount_ < 20) {
        std::cerr << "[FfmpegDecoder] frames_out=" << framesDecoded << std::endl;
    }

    return true;
}

void FfmpegDecoder::Reset() {
    if (ctx_) {
        avcodec_flush_buffers(ctx_);
    }
    decodeCount_ = 0;
}

void FfmpegDecoder::Shutdown() {
    if (frame_) {
        av_frame_free(&frame_);
    }
    if (ctx_) {
        avcodec_free_context(&ctx_);
    }
    decodeCount_ = 0;
}

} // namespace peariscope
