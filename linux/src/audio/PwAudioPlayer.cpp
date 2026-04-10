#include "PwAudioPlayer.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <cstring>
#include <algorithm>

namespace peariscope {

static const struct pw_stream_events kPlayerEvents = {
    .version = PW_VERSION_STREAM_EVENTS,
    .process = PwAudioPlayer::onProcess,
};

PwAudioPlayer::PwAudioPlayer() {
    pw_init(nullptr, nullptr);
}

PwAudioPlayer::~PwAudioPlayer() {
    Stop();
    pw_deinit();
}

bool PwAudioPlayer::Start(uint32_t sampleRate, uint32_t channels) {
    if (running_.load())
        return false;

    sampleRate_ = sampleRate;
    channels_ = channels;
    playbackStarted_ = false;

    loop_ = pw_thread_loop_new("pw-player", nullptr);
    if (!loop_)
        return false;

    auto* props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Music",
        nullptr);

    stream_ = pw_stream_new_simple(
        pw_thread_loop_get_loop(loop_),
        "peariscope-playback",
        props,
        &kPlayerEvents,
        this);

    if (!stream_) {
        pw_thread_loop_destroy(loop_);
        loop_ = nullptr;
        return false;
    }

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));

    struct spa_audio_info_raw info = {};
    info.format = SPA_AUDIO_FORMAT_F32;
    info.rate = sampleRate_;
    info.channels = channels_;

    const struct spa_pod* params[1];
    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);

    pw_stream_connect(stream_,
                      PW_DIRECTION_OUTPUT,
                      PW_ID_ANY,
                      static_cast<pw_stream_flags>(
                          PW_STREAM_FLAG_AUTOCONNECT |
                          PW_STREAM_FLAG_MAP_BUFFERS |
                          PW_STREAM_FLAG_RT_PROCESS),
                      params, 1);

    pw_thread_loop_start(loop_);
    running_.store(true);
    return true;
}

void PwAudioPlayer::QueuePcm(const float* data, uint32_t frameCount) {
    std::lock_guard<std::mutex> lock(bufferMutex_);

    uint32_t sampleCount = frameCount * channels_;
    pcmBuffer_.insert(pcmBuffer_.end(), data, data + sampleCount);

    // Cap buffer at 10 seconds of audio
    uint32_t maxSamples = sampleRate_ * channels_ * 10;
    while (pcmBuffer_.size() > maxSamples) {
        pcmBuffer_.pop_front();
    }
}

void PwAudioPlayer::Stop() {
    if (!running_.load())
        return;

    running_.store(false);

    if (loop_)
        pw_thread_loop_stop(loop_);

    if (stream_) {
        pw_stream_destroy(stream_);
        stream_ = nullptr;
    }

    if (loop_) {
        pw_thread_loop_destroy(loop_);
        loop_ = nullptr;
    }

    {
        std::lock_guard<std::mutex> lock(bufferMutex_);
        pcmBuffer_.clear();
        playbackStarted_ = false;
    }
}

void PwAudioPlayer::onProcess(void* userdata) {
    auto* self = static_cast<PwAudioPlayer*>(userdata);

    struct pw_buffer* pwBuf = pw_stream_dequeue_buffer(self->stream_);
    if (!pwBuf)
        return;

    struct spa_buffer* buf = pwBuf->buffer;
    auto* dst = static_cast<float*>(buf->datas[0].data);
    if (!dst)
        goto done;

    {
        uint32_t maxFrames = buf->datas[0].maxsize / (sizeof(float) * self->channels_);
        uint32_t nFrames = 0;

        std::lock_guard<std::mutex> lock(self->bufferMutex_);

        // Jitter buffer: wait until we have enough data before starting playback
        if (!self->playbackStarted_) {
            uint32_t bufferedFrames = static_cast<uint32_t>(
                self->pcmBuffer_.size() / self->channels_);
            if (bufferedFrames < kJitterFrames) {
                // Output silence while buffering
                std::memset(dst, 0, maxFrames * sizeof(float) * self->channels_);
                buf->datas[0].chunk->offset = 0;
                buf->datas[0].chunk->stride = sizeof(float) * self->channels_;
                buf->datas[0].chunk->size = maxFrames * sizeof(float) * self->channels_;
                goto done;
            }
            self->playbackStarted_ = true;
        }

        uint32_t availableFrames = static_cast<uint32_t>(
            self->pcmBuffer_.size() / self->channels_);
        nFrames = std::min(maxFrames, availableFrames);

        uint32_t nSamples = nFrames * self->channels_;
        for (uint32_t i = 0; i < nSamples; ++i) {
            dst[i] = self->pcmBuffer_.front();
            self->pcmBuffer_.pop_front();
        }

        // Zero-fill remainder if not enough data
        if (nFrames < maxFrames) {
            std::memset(dst + nSamples, 0,
                        (maxFrames - nFrames) * sizeof(float) * self->channels_);
        }

        buf->datas[0].chunk->offset = 0;
        buf->datas[0].chunk->stride = sizeof(float) * self->channels_;
        buf->datas[0].chunk->size = maxFrames * sizeof(float) * self->channels_;
    }

done:
    pw_stream_queue_buffer(self->stream_, pwBuf);
}

} // namespace peariscope
