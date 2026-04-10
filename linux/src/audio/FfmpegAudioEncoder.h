#pragma once
#include <functional>
#include <vector>
#include <cstdint>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;

namespace peariscope {

class FfmpegAudioEncoder {
public:
    using OnEncodedData = std::function<void(const uint8_t* data, uint32_t size)>;

    FfmpegAudioEncoder();
    ~FfmpegAudioEncoder();

    bool Start(uint32_t sampleRate, uint32_t channels, uint32_t bitrate = 128000);
    void Encode(const float* pcmData, uint32_t frameCount);
    void Stop();
    void SetOnEncodedData(OnEncodedData callback) { callback_ = std::move(callback); }

private:
    AVCodecContext* ctx_ = nullptr;
    AVFrame* frame_ = nullptr;
    AVPacket* packet_ = nullptr;
    OnEncodedData callback_;
    uint32_t sampleRate_ = 48000;
    uint32_t channels_ = 2;
    std::vector<float> pendingPcm_;
    uint64_t inputTimestamp_ = 0;
    bool started_ = false;
    static constexpr uint32_t kAacFrameSize = 1024;
};

} // namespace peariscope
