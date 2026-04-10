#include "FfmpegAudioDecoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/channel_layout.h>
}

#include <cstring>

namespace peariscope {

FfmpegAudioDecoder::FfmpegAudioDecoder() = default;

FfmpegAudioDecoder::~FfmpegAudioDecoder() {
    Stop();
}

bool FfmpegAudioDecoder::Start(uint32_t sampleRate, uint32_t channels) {
    if (started_)
        return false;

    sampleRate_ = sampleRate;
    channels_ = channels;

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_AAC);
    if (!codec)
        return false;

    ctx_ = avcodec_alloc_context3(codec);
    if (!ctx_)
        return false;

    ctx_->sample_rate = static_cast<int>(sampleRate_);

    AVChannelLayout layout = {};
    if (channels_ == 1)
        layout = AV_CHANNEL_LAYOUT_MONO;
    else
        layout = AV_CHANNEL_LAYOUT_STEREO;

    av_channel_layout_copy(&ctx_->ch_layout, &layout);

    if (avcodec_open2(ctx_, codec, nullptr) < 0) {
        avcodec_free_context(&ctx_);
        return false;
    }

    frame_ = av_frame_alloc();
    if (!frame_) {
        avcodec_free_context(&ctx_);
        return false;
    }

    packet_ = av_packet_alloc();
    if (!packet_) {
        av_frame_free(&frame_);
        avcodec_free_context(&ctx_);
        return false;
    }

    started_ = true;
    return true;
}

void FfmpegAudioDecoder::Decode(const uint8_t* aacData, uint32_t size) {
    if (!started_ || !aacData || size == 0)
        return;

    packet_->data = const_cast<uint8_t*>(aacData);
    packet_->size = static_cast<int>(size);

    int ret = avcodec_send_packet(ctx_, packet_);
    if (ret < 0)
        return;

    while (ret >= 0) {
        ret = avcodec_receive_frame(ctx_, frame_);
        if (ret < 0)
            break;

        uint32_t nFrames = static_cast<uint32_t>(frame_->nb_samples);
        uint32_t nChannels = static_cast<uint32_t>(frame_->ch_layout.nb_channels);

        // Convert planar float to interleaved float
        interleavedBuf_.resize(nFrames * nChannels);

        if (frame_->format == AV_SAMPLE_FMT_FLTP) {
            for (uint32_t s = 0; s < nFrames; ++s) {
                for (uint32_t ch = 0; ch < nChannels; ++ch) {
                    auto* src = reinterpret_cast<const float*>(frame_->data[ch]);
                    interleavedBuf_[s * nChannels + ch] = src[s];
                }
            }
        } else if (frame_->format == AV_SAMPLE_FMT_FLT) {
            // Already interleaved
            auto* src = reinterpret_cast<const float*>(frame_->data[0]);
            std::memcpy(interleavedBuf_.data(), src,
                        nFrames * nChannels * sizeof(float));
        }

        if (callback_)
            callback_(interleavedBuf_.data(), nFrames,
                      static_cast<uint32_t>(frame_->sample_rate), nChannels);

        av_frame_unref(frame_);
    }
}

void FfmpegAudioDecoder::Stop() {
    if (!started_)
        return;

    started_ = false;

    if (packet_) {
        av_packet_free(&packet_);
        packet_ = nullptr;
    }
    if (frame_) {
        av_frame_free(&frame_);
        frame_ = nullptr;
    }
    if (ctx_) {
        avcodec_free_context(&ctx_);
        ctx_ = nullptr;
    }

    interleavedBuf_.clear();
}

} // namespace peariscope
