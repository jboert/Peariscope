#pragma once
#include <functional>
#include <atomic>
#include <cstdint>

struct pw_thread_loop;
struct pw_stream;

namespace peariscope {

class PwAudioCapture {
public:
    using OnAudioData = std::function<void(const float* data, uint32_t frames,
                                           uint32_t sampleRate, uint32_t channels)>;
    PwAudioCapture();
    ~PwAudioCapture();

    bool Start(OnAudioData callback);
    void Stop();
    bool IsRunning() const { return running_.load(); }
    uint32_t GetSampleRate() const { return sampleRate_; }
    uint32_t GetChannels() const { return channels_; }

// PipeWire callback - needs to be accessible from C struct initializer
    static void onProcess(void* userdata);

private:
    pw_thread_loop* loop_ = nullptr;
    pw_stream* stream_ = nullptr;
    OnAudioData callback_;
    std::atomic<bool> running_{false};
    uint32_t sampleRate_ = 48000;
    uint32_t channels_ = 2;
};

} // namespace peariscope
