#include "GlRenderer.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <cstring>
#include <cstdio>
#include <iostream>
#include <algorithm>

extern "C" {
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}

namespace peariscope {

GlRenderer::GlRenderer() = default;

GlRenderer::~GlRenderer() {
    Shutdown();
}

void GlRenderer::RecalcFit() {
    if (width_ == 0 || height_ == 0 || windowWidth_ == 0 || windowHeight_ == 0) return;

    // Aspect-ratio-preserving fit (letterbox/pillarbox)
    float scaleX = static_cast<float>(windowWidth_) / static_cast<float>(width_);
    float scaleY = static_cast<float>(windowHeight_) / static_cast<float>(height_);
    float scale = std::min(scaleX, scaleY);

    fitW_ = static_cast<uint32_t>(width_ * scale);
    fitH_ = static_cast<uint32_t>(height_ * scale);
    fitX_ = (windowWidth_ - fitW_) / 2;
    fitY_ = (windowHeight_ - fitH_) / 2;

    // Ensure even dimensions for sws_scale
    fitW_ &= ~1u;
    fitH_ &= ~1u;
    if (fitW_ == 0) fitW_ = 2;
    if (fitH_ == 0) fitH_ = 2;
}

bool GlRenderer::Initialize(void* display, unsigned long window,
                             uint32_t width, uint32_t height) {
    if (initialized_) return true;

    display_ = display;
    window_ = window;
    width_ = width;
    height_ = height;

    Display* dpy = static_cast<Display*>(display_);

    // Get window dimensions
    XWindowAttributes attrs;
    if (XGetWindowAttributes(dpy, window_, &attrs)) {
        windowWidth_ = static_cast<uint32_t>(attrs.width);
        windowHeight_ = static_cast<uint32_t>(attrs.height);
    } else {
        windowWidth_ = width;
        windowHeight_ = height;
    }

    RecalcFit();

    // Create GC for drawing
    gc_ = static_cast<void*>(XCreateGC(dpy, window_, 0, nullptr));

    // Allocate RGB buffer at fitted size
    rgbBuf_.resize(static_cast<size_t>(fitW_) * fitH_ * 4);
    std::memset(rgbBuf_.data(), 0, rgbBuf_.size());

    // Create XImage at fitted size
    int screen = DefaultScreen(dpy);
    ximage_ = static_cast<void*>(XCreateImage(dpy, DefaultVisual(dpy, screen),
        DefaultDepth(dpy, screen), ZPixmap, 0,
        reinterpret_cast<char*>(rgbBuf_.data()),
        fitW_, fitH_, 32, 0));

    if (!ximage_) {
        std::cerr << "[GlRenderer] Failed to create XImage" << std::endl;
        return false;
    }

    // Create sws context: scale from frame size → fitted size, YUV420P → BGRA
    sws_ = sws_getContext(
        static_cast<int>(width), static_cast<int>(height), AV_PIX_FMT_YUV420P,
        static_cast<int>(fitW_), static_cast<int>(fitH_), AV_PIX_FMT_BGRA,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);

    if (!sws_) {
        std::cerr << "[GlRenderer] Failed to create SwsContext" << std::endl;
        return false;
    }

    // Suppress expose-event flashing: set black background
    XSetWindowBackground(dpy, window_, BlackPixel(dpy, DefaultScreen(dpy)));

    initialized_ = true;
    std::cerr << "[GlRenderer] Initialized: frame=" << width << "x" << height
              << " window=" << windowWidth_ << "x" << windowHeight_
              << " fit=" << fitW_ << "x" << fitH_
              << " offset=" << fitX_ << "," << fitY_ << std::endl;
    return true;
}

void GlRenderer::Present(AVFrame* frame) {
    if (!initialized_ || !frame || !ximage_) return;

    uint32_t fw = static_cast<uint32_t>(frame->width);
    uint32_t fh = static_cast<uint32_t>(frame->height);

    // If frame dimensions changed, recreate sws scaler with new fit
    if (fw != width_ || fh != height_) {
        width_ = fw;
        height_ = fh;
        RecalcFit();

        if (sws_) { sws_freeContext(sws_); sws_ = nullptr; }

        // Recreate XImage at new fit size
        if (ximage_) {
            XImage* img = static_cast<XImage*>(ximage_);
            img->data = nullptr;
            XDestroyImage(img);
            ximage_ = nullptr;
        }

        rgbBuf_.resize(static_cast<size_t>(fitW_) * fitH_ * 4);
        std::memset(rgbBuf_.data(), 0, rgbBuf_.size());

        Display* dpy = static_cast<Display*>(display_);
        int screen = DefaultScreen(dpy);
        ximage_ = static_cast<void*>(XCreateImage(dpy, DefaultVisual(dpy, screen),
            DefaultDepth(dpy, screen), ZPixmap, 0,
            reinterpret_cast<char*>(rgbBuf_.data()),
            fitW_, fitH_, 32, 0));

        sws_ = sws_getContext(
            static_cast<int>(fw), static_cast<int>(fh), AV_PIX_FMT_YUV420P,
            static_cast<int>(fitW_), static_cast<int>(fitH_), AV_PIX_FMT_BGRA,
            SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);

        if (!sws_ || !ximage_) return;

        // Clear window to black (removes old stretched content)
        Display* d = static_cast<Display*>(display_);
        XClearWindow(d, window_);

        std::cerr << "[GlRenderer] Frame size changed to " << fw << "x" << fh
                  << " fit=" << fitW_ << "x" << fitH_
                  << " offset=" << fitX_ << "," << fitY_ << std::endl;
    }

    // Convert + scale YUV420P → BGRA at fitted size
    uint8_t* dst[1] = { rgbBuf_.data() };
    int dstStride[1] = { static_cast<int>(fitW_ * 4) };

    sws_scale(sws_, frame->data, frame->linesize, 0,
              static_cast<int>(fh), dst, dstStride);

    // Draw to window at centered offset (pillarbox/letterbox)
    Display* dpy = static_cast<Display*>(display_);
    XImage* img = static_cast<XImage*>(ximage_);
    GC gc = static_cast<GC>(gc_);

    XPutImage(dpy, window_, gc, img, 0, 0,
              static_cast<int>(fitX_), static_cast<int>(fitY_),
              fitW_, fitH_);
    XFlush(dpy);
}

void GlRenderer::Resize(uint32_t width, uint32_t height) {
    if (!display_) return;
    if (width == windowWidth_ && height == windowHeight_) return;
    if (width == 0 || height == 0) return;

    windowWidth_ = width;
    windowHeight_ = height;
    RecalcFit();

    Display* dpy = static_cast<Display*>(display_);

    // Destroy old XImage
    if (ximage_) {
        XImage* img = static_cast<XImage*>(ximage_);
        img->data = nullptr;
        XDestroyImage(img);
        ximage_ = nullptr;
    }

    if (sws_) { sws_freeContext(sws_); sws_ = nullptr; }

    // Reallocate buffer at new fitted size
    rgbBuf_.resize(static_cast<size_t>(fitW_) * fitH_ * 4);
    std::memset(rgbBuf_.data(), 0, rgbBuf_.size());

    // Create new XImage
    int screen = DefaultScreen(dpy);
    ximage_ = static_cast<void*>(XCreateImage(dpy, DefaultVisual(dpy, screen),
        DefaultDepth(dpy, screen), ZPixmap, 0,
        reinterpret_cast<char*>(rgbBuf_.data()),
        fitW_, fitH_, 32, 0));

    // Create new sws context
    if (width_ > 0 && height_ > 0) {
        sws_ = sws_getContext(
            static_cast<int>(width_), static_cast<int>(height_), AV_PIX_FMT_YUV420P,
            static_cast<int>(fitW_), static_cast<int>(fitH_), AV_PIX_FMT_BGRA,
            SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    }

    // Clear window to show black bars
    XClearWindow(dpy, window_);

    std::cerr << "[GlRenderer] Window resized to " << width << "x" << height
              << " fit=" << fitW_ << "x" << fitH_ << std::endl;
}

void GlRenderer::Shutdown() {
    if (ximage_) {
        XImage* img = static_cast<XImage*>(ximage_);
        img->data = nullptr;
        XDestroyImage(img);
        ximage_ = nullptr;
    }

    if (sws_) {
        sws_freeContext(sws_);
        sws_ = nullptr;
    }

    if (display_ && gc_) {
        XFreeGC(static_cast<Display*>(display_), static_cast<GC>(gc_));
        gc_ = nullptr;
    }

    rgbBuf_.clear();
    initialized_ = false;
}

} // namespace peariscope
