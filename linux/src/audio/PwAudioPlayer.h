#pragma once
#include <mutex>
#include <deque>
#include <atomic>
#include <cstdint>

struct pw_thread_loop;
struct pw_stream;

namespace peariscope {

class PwAudioPlayer {
public:
    PwAudioPlayer();
    ~PwAudioPlayer();

    bool Start(uint32_t sampleRate = 48000, uint32_t channels = 2);
    void QueuePcm(const float* data, uint32_t frameCount);
    void Stop();

    static void onProcess(void* userdata);

private:
    pw_thread_loop* loop_ = nullptr;
    pw_stream* stream_ = nullptr;
    std::mutex bufferMutex_;
    std::deque<float> pcmBuffer_;
    std::atomic<bool> running_{false};
    uint32_t sampleRate_ = 48000;
    uint32_t channels_ = 2;

    static constexpr uint32_t kJitterFrames = 1024 * 3;
    bool playbackStarted_ = false;
};

} // namespace peariscope
