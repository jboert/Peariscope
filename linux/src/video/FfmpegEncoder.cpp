#include "FfmpegEncoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#include <iostream>
#include <cstring>

namespace peariscope {

FfmpegEncoder::FfmpegEncoder() = default;
FfmpegEncoder::~FfmpegEncoder() { Shutdown(); }

bool FfmpegEncoder::Initialize(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate) {
    width_ = width;
    height_ = height;
    fps_ = fps;
    bitrate_ = bitrate;
    frameCount_ = 0;
    forceKeyframe_ = true;  // First frame must be a keyframe (SPS+PPS+IDR)

    return InitCodec(width, height, fps, bitrate);
}

bool FfmpegEncoder::InitCodec(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate) {
    // Use libx264 directly (VAAPI requires special pixel format setup)
    const AVCodec* codec = avcodec_find_encoder_by_name("libx264");
    bool usingVaapi = false;
    if (!codec) {
        // Last resort: find any H.264 encoder
        codec = avcodec_find_encoder(AV_CODEC_ID_H264);
    }
    if (!codec) {
        std::cerr << "[FfmpegEncoder] No H.264 encoder found" << std::endl;
        return false;
    }

    std::cerr << "[FfmpegEncoder] Using encoder: " << codec->name << std::endl;

    ctx_ = avcodec_alloc_context3(codec);
    if (!ctx_) {
        std::cerr << "[FfmpegEncoder] Failed to allocate codec context" << std::endl;
        return false;
    }

    ctx_->width = static_cast<int>(width);
    ctx_->height = static_cast<int>(height);
    ctx_->time_base = {1, static_cast<int>(fps)};
    ctx_->framerate = {static_cast<int>(fps), 1};
    ctx_->bit_rate = bitrate;
    ctx_->gop_size = 30; // keyframe every 1s at 30fps — match Mac's pattern
    ctx_->max_b_frames = 0;
    ctx_->pix_fmt = AV_PIX_FMT_YUV420P;
    ctx_->thread_count = 0;
    ctx_->flags |= AV_CODEC_FLAG_LOW_DELAY;

    if (!usingVaapi) {
        if (std::string(codec->name) == "libx264") {
            av_opt_set(ctx_->priv_data, "preset", "veryfast", 0);
            // Don't use tune=zerolatency — it enables intra-refresh which prevents IDR frames.
            // Instead, set the low-latency options manually:
            av_opt_set(ctx_->priv_data, "profile", "main", 0);
            // VBV maxrate/bufsize in kbps — must match target bitrate for clean motion.
            // Previous values (4000/2000) caused severe artifacting because the encoder
            // was capped at 4 Mbps despite a 20 Mbps target bitrate.
            uint32_t vbvMaxrateKbps = bitrate / 1000;
            uint32_t vbvBufsizeKbps = vbvMaxrateKbps / 2; // 0.5s buffer at max rate
            std::string x264params =
                "bframes=0:rc-lookahead=0:sync-lookahead=0:sliced-threads=0"
                ":slices=1:open-gop=0:keyint=30:min-keyint=30"
                ":vbv-maxrate=" + std::to_string(vbvMaxrateKbps) +
                ":vbv-bufsize=" + std::to_string(vbvBufsizeKbps) +
                ":intra-refresh=0:aq-mode=2";
            av_opt_set(ctx_->priv_data, "x264-params", x264params.c_str(), 0);
        } else if (std::string(codec->name) == "libopenh264") {
            // OpenH264: maximize quality for real-time streaming
            av_opt_set(ctx_->priv_data, "allow_skip_frames", "0", 0);
            av_opt_set(ctx_->priv_data, "rc_mode", "bitrate", 0);
            ctx_->gop_size = 30; // more frequent keyframes to reduce artifact persistence
        }
    }

    int ret = avcodec_open2(ctx_, codec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        std::cerr << "[FfmpegEncoder] avcodec_open2 failed: " << errbuf << std::endl;

        // If VAAPI failed, fall back to libx264
        if (usingVaapi) {
            std::cerr << "[FfmpegEncoder] VAAPI failed, falling back to libx264" << std::endl;
            avcodec_free_context(&ctx_);

            codec = avcodec_find_encoder_by_name("libx264");
            if (!codec) codec = avcodec_find_encoder(AV_CODEC_ID_H264);
            if (!codec) return false;

            ctx_ = avcodec_alloc_context3(codec);
            if (!ctx_) return false;

            ctx_->width = static_cast<int>(width);
            ctx_->height = static_cast<int>(height);
            ctx_->time_base = {1, static_cast<int>(fps)};
            ctx_->framerate = {static_cast<int>(fps), 1};
            ctx_->bit_rate = bitrate;
            ctx_->bit_rate = bitrate;
            ctx_->gop_size = 60;
            ctx_->max_b_frames = 0;
            ctx_->pix_fmt = AV_PIX_FMT_YUV420P;
            ctx_->thread_count = 0;
            ctx_->flags |= AV_CODEC_FLAG_LOW_DELAY;

            av_opt_set(ctx_->priv_data, "preset", "superfast", 0);
            av_opt_set(ctx_->priv_data, "tune", "zerolatency", 0);
            av_opt_set(ctx_->priv_data, "profile", "high", 0);
            av_opt_set(ctx_->priv_data, "x264-params",
                "vbv-maxrate=10000:vbv-bufsize=5000",
                0);

            ret = avcodec_open2(ctx_, codec, nullptr);
            if (ret < 0) {
                av_strerror(ret, errbuf, sizeof(errbuf));
                std::cerr << "[FfmpegEncoder] libx264 fallback also failed: " << errbuf << std::endl;
                avcodec_free_context(&ctx_);
                return false;
            }
        } else {
            avcodec_free_context(&ctx_);
            return false;
        }
    }

    // Cache SPS/PPS from extradata (if codec provides it)
    if (ctx_->extradata && ctx_->extradata_size > 0) {
        CacheSpsPs(ctx_->extradata, ctx_->extradata_size);
    }

    // Allocate frame for YUV420P data
    frame_ = av_frame_alloc();
    if (!frame_) {
        std::cerr << "[FfmpegEncoder] Failed to allocate frame" << std::endl;
        avcodec_free_context(&ctx_);
        return false;
    }
    frame_->format = AV_PIX_FMT_YUV420P;
    frame_->width = static_cast<int>(width);
    frame_->height = static_cast<int>(height);

    ret = av_frame_get_buffer(frame_, 0);
    if (ret < 0) {
        std::cerr << "[FfmpegEncoder] Failed to allocate frame buffer" << std::endl;
        av_frame_free(&frame_);
        avcodec_free_context(&ctx_);
        return false;
    }

    // Create SwsContext for BGRA → YUV420P conversion
    sws_ = sws_getContext(
        static_cast<int>(width), static_cast<int>(height), AV_PIX_FMT_BGRA,
        static_cast<int>(width), static_cast<int>(height), AV_PIX_FMT_YUV420P,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr
    );
    if (!sws_) {
        std::cerr << "[FfmpegEncoder] Failed to create SwsContext" << std::endl;
        av_frame_free(&frame_);
        avcodec_free_context(&ctx_);
        return false;
    }

    std::cerr << "[FfmpegEncoder] Initialized: " << width << "x" << height
              << " fps=" << fps << " bitrate=" << bitrate
              << " codec=" << ctx_->codec->name << std::endl;

    // Debug: dump first 5 seconds to file for verification
    debugDumpFile_ = fopen("/tmp/peariscope-debug.h264", "wb");
    debugDumpFrames_ = 150; // 5 seconds at 30fps

    return true;
}

void FfmpegEncoder::CacheSpsPs(const uint8_t* extradata, int size) {
    // Parse Annex B extradata for SPS (type 7) and PPS (type 8) NAL units
    for (int i = 0; i + 3 < size; ++i) {
        uint8_t nalType = 0;
        int startCodeLen = 0;

        if (i + 4 < size && extradata[i] == 0 && extradata[i+1] == 0 &&
            extradata[i+2] == 0 && extradata[i+3] == 1) {
            startCodeLen = 4;
            nalType = extradata[i+4] & 0x1F;
        } else if (extradata[i] == 0 && extradata[i+1] == 0 && extradata[i+2] == 1) {
            startCodeLen = 3;
            nalType = extradata[i+3] & 0x1F;
        } else {
            continue;
        }

        // Find end of this NAL unit (next start code or end of data)
        int nalStart = i;
        int nalEnd = size;
        int searchFrom = i + startCodeLen + 1;
        for (int j = searchFrom; j + 2 < size; ++j) {
            if (extradata[j] == 0 && extradata[j+1] == 0 &&
                (extradata[j+2] == 1 || (j + 3 < size && extradata[j+2] == 0 && extradata[j+3] == 1))) {
                nalEnd = j;
                break;
            }
        }

        if (nalType == 7) {
            cachedSps_.assign(extradata + nalStart, extradata + nalEnd);
        } else if (nalType == 8) {
            cachedPps_.assign(extradata + nalStart, extradata + nalEnd);
        }

        i = nalStart + startCodeLen; // advance past start code
    }
}

bool FfmpegEncoder::Encode(const uint8_t* bgraData, uint32_t stride, uint64_t timestamp) {
    if (!ctx_ || !frame_ || !sws_) return false;

    // Make frame writable
    int ret = av_frame_make_writable(frame_);
    if (ret < 0) return false;

    // Convert BGRA → YUV420P
    const uint8_t* srcSlice[1] = { bgraData };
    int srcStride[1] = { static_cast<int>(stride) };

    sws_scale(sws_, srcSlice, srcStride, 0, static_cast<int>(height_),
              frame_->data, frame_->linesize);

    frame_->pts = static_cast<int64_t>(frameCount_);
    frameCount_++;

    // Force IDR keyframe if requested — iOS requires NAL type 5 (IDR), not type 1 (I-slice)
    if (forceKeyframe_ || (frameCount_ % static_cast<uint64_t>(ctx_->gop_size) == 0)) {
        frame_->pict_type = AV_PICTURE_TYPE_I;
        frame_->key_frame = 1;
        // Force IDR: set AV_FRAME_FLAG_KEY which tells libx264 to produce IDR not just I-frame
        frame_->flags |= AV_FRAME_FLAG_KEY;
        forceKeyframe_ = false;
    } else {
        frame_->pict_type = AV_PICTURE_TYPE_NONE;
        frame_->key_frame = 0;
        frame_->flags &= ~AV_FRAME_FLAG_KEY;
    }

    // Send frame to encoder
    ret = avcodec_send_frame(ctx_, frame_);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        std::cerr << "[FfmpegEncoder] avcodec_send_frame failed: " << errbuf << std::endl;
        return false;
    }

    // Receive all available encoded packets
    return ProcessEncodedPacket();
}

bool FfmpegEncoder::ProcessEncodedPacket() {
    AVPacket* pkt = av_packet_alloc();
    if (!pkt) return false;

    while (true) {
        int ret = avcodec_receive_packet(ctx_, pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            std::cerr << "[FfmpegEncoder] avcodec_receive_packet failed: " << errbuf << std::endl;
            av_packet_free(&pkt);
            return false;
        }

        // Debug dump
        if (debugDumpFile_ && debugDumpFrames_ > 0 && pkt->data && pkt->size > 0) {
            fwrite(pkt->data, 1, pkt->size, debugDumpFile_);
            debugDumpFrames_--;
            if (debugDumpFrames_ == 0) {
                fclose(debugDumpFile_);
                debugDumpFile_ = nullptr;
                std::cerr << "[FfmpegEncoder] Debug dump complete: /tmp/peariscope-debug.h264" << std::endl;
            }
        }

        if (callback_ && pkt->data && pkt->size > 0) {
            bool isKeyframe = (pkt->flags & AV_PKT_FLAG_KEY) != 0;

            // Parse NAL units to check for SPS/PPS and cache them
            bool hasSps = false;
            bool hasPps = false;

            for (int i = 0; i + 3 < pkt->size; ++i) {
                uint8_t nalType = 0;
                int startCodeLen = 0;

                if (i + 4 < pkt->size && pkt->data[i] == 0 && pkt->data[i+1] == 0 &&
                    pkt->data[i+2] == 0 && pkt->data[i+3] == 1) {
                    startCodeLen = 4;
                    nalType = pkt->data[i+4] & 0x1F;
                } else if (pkt->data[i] == 0 && pkt->data[i+1] == 0 && pkt->data[i+2] == 1) {
                    startCodeLen = 3;
                    nalType = pkt->data[i+3] & 0x1F;
                } else {
                    continue;
                }

                if (nalType == 7) hasSps = true;
                if (nalType == 8) hasPps = true;
                i += startCodeLen; // skip past start code
            }

            // Cache SPS/PPS from keyframes
            if (isKeyframe && (hasSps || hasPps)) {
                CacheSpsPs(pkt->data, pkt->size);
            }

            // ALWAYS prepend SPS/PPS to keyframes — iOS VideoToolbox requires it
            if (isKeyframe && !cachedSps_.empty() && !cachedPps_.empty()) {
                std::vector<uint8_t> augmented;
                augmented.reserve(cachedSps_.size() + cachedPps_.size() +
                                  static_cast<size_t>(pkt->size));
                augmented.insert(augmented.end(), cachedSps_.begin(), cachedSps_.end());
                augmented.insert(augmented.end(), cachedPps_.begin(), cachedPps_.end());
                // Strip any existing SPS/PPS from the packet to avoid duplicates
                const uint8_t* payloadStart = pkt->data;
                size_t payloadSize = static_cast<size_t>(pkt->size);
                // Skip over inline SPS/PPS NAL units — find first non-SPS/PPS NAL
                if (hasSps || hasPps) {
                    const uint8_t* p = pkt->data;
                    const uint8_t* end = p + pkt->size;
                    const uint8_t* lastNonParam = nullptr;
                    while (p < end - 4) {
                        if (p[0] == 0 && p[1] == 0 && ((p[2] == 1) || (p[2] == 0 && p[3] == 1))) {
                            int offset = (p[2] == 1) ? 3 : 4;
                            uint8_t nalType = p[offset] & 0x1F;
                            if (nalType != 7 && nalType != 8) { // not SPS or PPS
                                lastNonParam = p;
                                break;
                            }
                        }
                        p++;
                    }
                    if (lastNonParam) {
                        payloadStart = lastNonParam;
                        payloadSize = end - lastNonParam;
                    }
                }
                augmented.insert(augmented.end(), payloadStart, payloadStart + payloadSize);
                callback_(augmented.data(), augmented.size(), true);
            } else {
                callback_(pkt->data, static_cast<size_t>(pkt->size), isKeyframe);
            }
        }

        av_packet_unref(pkt);
    }

    av_packet_free(&pkt);
    return true;
}

void FfmpegEncoder::ForceKeyframe() {
    forceKeyframe_ = true;
}

void FfmpegEncoder::SetBitrate(uint32_t bitrate) {
    bitrate_ = bitrate;
    if (ctx_) {
        ctx_->bit_rate = bitrate;
    }
}

void FfmpegEncoder::Shutdown() {
    if (sws_) {
        sws_freeContext(sws_);
        sws_ = nullptr;
    }
    if (frame_) {
        av_frame_free(&frame_);
    }
    if (ctx_) {
        avcodec_free_context(&ctx_);
    }
    cachedSps_.clear();
    cachedPps_.clear();
    frameCount_ = 0;
}

} // namespace peariscope
