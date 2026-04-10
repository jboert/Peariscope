#pragma once

#include <functional>
#include <cstdint>

struct AVCodecContext;
struct AVFrame;

namespace peariscope {

/// H.264/H.265 decoder using FFmpeg.
/// Auto-detects codec from NAL unit type on first packet.
class FfmpegDecoder {
public:
    /// Called with decoded YUV420P frame
    using DecodedCallback = std::function<void(AVFrame* frame, uint64_t timestamp)>;

    enum class CodecType { Unknown, H264, H265 };

    FfmpegDecoder();
    ~FfmpegDecoder();

    /// Initialize decoder with specific codec (or Unknown for auto-detect)
    bool Initialize(uint32_t width, uint32_t height, CodecType codec = CodecType::Unknown);

    /// Decode Annex B H.264/H.265 data (auto-detects codec on first call if Unknown)
    bool Decode(const uint8_t* data, size_t size);

    /// Flush decoder state so it can recover on next keyframe
    void Reset();

    /// Set decoded frame callback
    void SetCallback(DecodedCallback callback) { callback_ = callback; }

    void Shutdown();

    CodecType detectedCodec() const { return detectedCodec_; }

private:
    bool InitCodec(uint32_t width, uint32_t height, CodecType codec);
    static CodecType DetectCodec(const uint8_t* data, size_t size);

    AVCodecContext* ctx_ = nullptr;
    AVFrame* frame_ = nullptr;
    DecodedCallback callback_;
    int decodeCount_ = 0;
    uint32_t initWidth_ = 0;
    uint32_t initHeight_ = 0;
    CodecType detectedCodec_ = CodecType::Unknown;
};

} // namespace peariscope
