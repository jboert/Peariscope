#pragma once
#include <functional>
#include <vector>
#include <cstdint>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;

namespace peariscope {

class FfmpegAudioDecoder {
public:
    using OnDecodedData = std::function<void(const float* pcmData, uint32_t frameCount,
                                              uint32_t sampleRate, uint32_t channels)>;
    FfmpegAudioDecoder();
    ~FfmpegAudioDecoder();

    bool Start(uint32_t sampleRate = 48000, uint32_t channels = 2);
    void Decode(const uint8_t* aacData, uint32_t size);
    void Stop();
    void SetOnDecodedData(OnDecodedData callback) { callback_ = std::move(callback); }

private:
    AVCodecContext* ctx_ = nullptr;
    AVFrame* frame_ = nullptr;
    AVPacket* packet_ = nullptr;
    OnDecodedData callback_;
    uint32_t sampleRate_ = 48000;
    uint32_t channels_ = 2;
    bool started_ = false;
    std::vector<float> interleavedBuf_;
};

} // namespace peariscope
