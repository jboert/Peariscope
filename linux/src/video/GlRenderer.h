#pragma once

#include <cstdint>
#include <functional>
#include <vector>

struct AVFrame;
struct SwsContext;

// Forward declare to avoid pulling in GL headers everywhere
typedef unsigned int GLuint;

namespace peariscope {

/// Renders decoded YUV420P frames to an X11 window.
/// Uses software YUV→BGRA conversion + XImage (no GLX threading issues).
class GlRenderer {
public:
    GlRenderer();
    ~GlRenderer();

    // Initialize with an X11 window for display (viewer mode)
    bool Initialize(void* display, unsigned long window, uint32_t width, uint32_t height);

    // Initialize without display (host mode - not needed on Linux since encoder takes raw pixels)
    bool InitializeDeviceOnly() { return true; }

    // Present a decoded YUV420P frame
    void Present(AVFrame* frame);

    void Resize(uint32_t width, uint32_t height);
    void Shutdown();

    uint32_t GetWidth() const { return width_; }
    uint32_t GetHeight() const { return height_; }

private:
    void* display_ = nullptr;  // Display*
    unsigned long window_ = 0; // Window
    void* gc_ = nullptr;       // GC
    void* ximage_ = nullptr;   // XImage*
    SwsContext* sws_ = nullptr;

    void RecalcFit();

    std::vector<uint8_t> rgbBuf_;   // scaled frame (fitW_ x fitH_)
    uint32_t width_ = 0;            // source frame width
    uint32_t height_ = 0;           // source frame height
    uint32_t windowWidth_ = 0;
    uint32_t windowHeight_ = 0;
    uint32_t fitW_ = 0;             // aspect-ratio-preserved output size
    uint32_t fitH_ = 0;
    uint32_t fitX_ = 0;             // offset to center in window
    uint32_t fitY_ = 0;
    bool initialized_ = false;
};

} // namespace peariscope
