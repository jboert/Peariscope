#include "FfmpegAudioEncoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
}

#include <cstring>

namespace peariscope {

FfmpegAudioEncoder::FfmpegAudioEncoder() = default;

FfmpegAudioEncoder::~FfmpegAudioEncoder() {
    Stop();
}

bool FfmpegAudioEncoder::Start(uint32_t sampleRate, uint32_t channels, uint32_t bitrate) {
    if (started_)
        return false;

    sampleRate_ = sampleRate;
    channels_ = channels;

    const AVCodec* codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!codec) {
        codec = avcodec_find_encoder_by_name("aac");
        if (!codec)
            return false;
    }

    ctx_ = avcodec_alloc_context3(codec);
    if (!ctx_)
        return false;

    ctx_->sample_fmt = AV_SAMPLE_FMT_FLTP;
    ctx_->sample_rate = static_cast<int>(sampleRate_);
    ctx_->bit_rate = static_cast<int64_t>(bitrate);

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

    frame_->format = ctx_->sample_fmt;
    av_channel_layout_copy(&frame_->ch_layout, &ctx_->ch_layout);
    frame_->sample_rate = ctx_->sample_rate;
    frame_->nb_samples = kAacFrameSize;

    if (av_frame_get_buffer(frame_, 0) < 0) {
        av_frame_free(&frame_);
        avcodec_free_context(&ctx_);
        return false;
    }

    packet_ = av_packet_alloc();
    if (!packet_) {
        av_frame_free(&frame_);
        avcodec_free_context(&ctx_);
        return false;
    }

    pendingPcm_.clear();
    inputTimestamp_ = 0;
    started_ = true;
    return true;
}

void FfmpegAudioEncoder::Encode(const float* pcmData, uint32_t frameCount) {
    if (!started_)
        return;

    uint32_t totalSamples = frameCount * channels_;
    pendingPcm_.insert(pendingPcm_.end(), pcmData, pcmData + totalSamples);

    uint32_t samplesPerFrame = kAacFrameSize * channels_;

    while (pendingPcm_.size() >= samplesPerFrame) {
        av_frame_make_writable(frame_);
        frame_->nb_samples = kAacFrameSize;
        frame_->pts = static_cast<int64_t>(inputTimestamp_);
        inputTimestamp_ += kAacFrameSize;

        // Convert interleaved float to planar float
        for (uint32_t ch = 0; ch < channels_; ++ch) {
            auto* dst = reinterpret_cast<float*>(frame_->data[ch]);
            for (uint32_t s = 0; s < kAacFrameSize; ++s) {
                dst[s] = pendingPcm_[s * channels_ + ch];
            }
        }

        // Remove consumed samples
        pendingPcm_.erase(pendingPcm_.begin(),
                          pendingPcm_.begin() + samplesPerFrame);

        int ret = avcodec_send_frame(ctx_, frame_);
        if (ret < 0)
            continue;

        while (ret >= 0) {
            ret = avcodec_receive_packet(ctx_, packet_);
            if (ret < 0)
                break;

            if (callback_)
                callback_(packet_->data, static_cast<uint32_t>(packet_->size));

            av_packet_unref(packet_);
        }
    }
}

void FfmpegAudioEncoder::Stop() {
    if (!started_)
        return;

    started_ = false;

    // Flush encoder
    if (ctx_) {
        avcodec_send_frame(ctx_, nullptr);
        while (true) {
            int ret = avcodec_receive_packet(ctx_, packet_);
            if (ret < 0)
                break;
            if (callback_)
                callback_(packet_->data, static_cast<uint32_t>(packet_->size));
            av_packet_unref(packet_);
        }
    }

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

    pendingPcm_.clear();
    inputTimestamp_ = 0;
}

} // namespace peariscope
