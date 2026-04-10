#pragma once

#include <functional>
#include <string>
#include <vector>
#include <cstdint>
#include <thread>
#include <atomic>
#include <mutex>

struct pw_thread_loop;
struct pw_stream;
struct pw_context;
struct pw_core;
struct spa_pod;

namespace peariscope {

struct NativeDisplayInfo {
    std::string name;
    uint32_t width;
    uint32_t height;
    uint32_t nodeId;
};

class PipewireCapture {
public:
    using FrameCallback = std::function<void(
        const uint8_t* data, uint32_t width, uint32_t height,
        uint32_t stride, uint64_t timestamp
    )>;

    PipewireCapture();
    ~PipewireCapture();

    // Start screen sharing (opens portal dialog for user to pick screen)
    bool Initialize();

    // Capture is push-based via PipeWire - frames arrive via callback
    void SetFrameCallback(FrameCallback callback) { frameCallback_ = callback; }

    uint32_t GetWidth() const { return width_; }
    uint32_t GetHeight() const { return height_; }

    void Shutdown();

    static std::vector<NativeDisplayInfo> EnumerateDisplays();

private:
    static void onStreamProcess(void* userdata);
    static void onStreamParamChanged(void* userdata, uint32_t id, const struct spa_pod* param);

    pw_thread_loop* loop_ = nullptr;
    pw_stream* stream_ = nullptr;
    pw_context* context_ = nullptr;
    pw_core* core_ = nullptr;

    FrameCallback frameCallback_;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    uint32_t nodeId_ = 0;
    int pwFd_ = -1;

    std::atomic<bool> running_{false};
    std::thread captureThread_;

    void* pwStreamState_ = nullptr; // opaque PwStreamState* for PipeWire capture
    bool InitializeX11();           // X11/XShm fallback
};

} // namespace peariscope
