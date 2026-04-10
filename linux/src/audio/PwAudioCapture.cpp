#include "PwAudioCapture.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <cstring>

namespace peariscope {

static const struct pw_stream_events kCaptureEvents = {
    .version = PW_VERSION_STREAM_EVENTS,
    .process = PwAudioCapture::onProcess,
};

PwAudioCapture::PwAudioCapture() {
    pw_init(nullptr, nullptr);
}

PwAudioCapture::~PwAudioCapture() {
    Stop();
    pw_deinit();
}

bool PwAudioCapture::Start(OnAudioData callback) {
    if (running_.load())
        return false;

    callback_ = std::move(callback);

    loop_ = pw_thread_loop_new("pw-capture", nullptr);
    if (!loop_)
        return false;

    auto* props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_STREAM_CAPTURE_SINK, "true",
        nullptr);

    stream_ = pw_stream_new_simple(
        pw_thread_loop_get_loop(loop_),
        "peariscope-capture",
        props,
        &kCaptureEvents,
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
                      PW_DIRECTION_INPUT,
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

void PwAudioCapture::Stop() {
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

    callback_ = nullptr;
}

void PwAudioCapture::onProcess(void* userdata) {
    auto* self = static_cast<PwAudioCapture*>(userdata);

    struct pw_buffer* pwBuf = pw_stream_dequeue_buffer(self->stream_);
    if (!pwBuf)
        return;

    struct spa_buffer* buf = pwBuf->buffer;
    if (!buf->datas[0].data)
        goto done;

    {
        auto* samples = static_cast<const float*>(buf->datas[0].data);
        uint32_t nBytes = buf->datas[0].chunk->size;
        uint32_t nFrames = nBytes / (sizeof(float) * self->channels_);

        if (self->callback_ && nFrames > 0)
            self->callback_(samples, nFrames, self->sampleRate_, self->channels_);
    }

done:
    pw_stream_queue_buffer(self->stream_, pwBuf);
}

} // namespace peariscope
