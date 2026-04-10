#pragma once

#include <functional>
#include <vector>
#include <cstdint>
#include <cstdio>

struct AVCodecContext;
struct AVFrame;
struct SwsContext;

namespace peariscope {

/// H.264 encoder using FFmpeg (libx264 with VAAPI fallback).
/// Replaces MfEncoder for the Linux port.
class FfmpegEncoder {
public:
    /// Called with encoded NAL units (Annex B format) ready for network transmission
    using EncodedCallback = std::function<void(
        const uint8_t* data, size_t size, bool isKeyframe
    )>;

    FfmpegEncoder();
    ~FfmpegEncoder();

    /// Initialize with dimensions. Takes raw BGRA pixel data (not D3D textures)
    bool Initialize(uint32_t width, uint32_t height, uint32_t fps = 30, uint32_t bitrate = 20000000);

    /// Encode a frame from raw BGRA pixel data
    bool Encode(const uint8_t* bgraData, uint32_t stride, uint64_t timestamp);

    /// Force next frame to be a keyframe
    void ForceKeyframe();

    /// Update bitrate
    void SetBitrate(uint32_t bitrate);

    /// Set encoded data callback
    void SetCallback(EncodedCallback callback) { callback_ = callback; }

    void Shutdown();

    uint32_t GetWidth() const { return width_; }
    uint32_t GetHeight() const { return height_; }

private:
    bool InitCodec(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate);
    void CacheSpsPs(const uint8_t* extradata, int size);
    bool ProcessEncodedPacket();

    AVCodecContext* ctx_ = nullptr;
    AVFrame* frame_ = nullptr;
    SwsContext* sws_ = nullptr;
    EncodedCallback callback_;

    uint32_t width_ = 0;
    uint32_t height_ = 0;
    uint32_t fps_ = 30;
    uint32_t bitrate_ = 20000000;

    bool forceKeyframe_ = false;
    uint64_t frameCount_ = 0;

    // Cached SPS/PPS for prepending to IDR frames
    std::vector<uint8_t> cachedSps_;
    std::vector<uint8_t> cachedPps_;

    // Debug: dump raw H.264 to file
    FILE* debugDumpFile_ = nullptr;
    int debugDumpFrames_ = 0;
};

} // namespace peariscope
