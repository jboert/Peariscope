#pragma once

#include <Windows.h>
#include <functional>
#include <cstdint>

namespace peariscope {

/// Captures keyboard and mouse input from the viewer window.
class InputCapture {
public:
    struct InputEvent {
        enum Type { KEY, MOUSE_MOVE, MOUSE_BUTTON, SCROLL };
        Type type;

        // Key
        uint32_t keycode = 0;
        uint32_t modifiers = 0;
        bool pressed = false;

        // Mouse
        float x = 0, y = 0;
        uint32_t button = 0;  // 0=left, 1=right, 2=middle
        float scrollDeltaX = 0, scrollDeltaY = 0;
    };

    using Callback = std::function<void(const InputEvent&)>;

    InputCapture();
    ~InputCapture();

    /// Start capturing from a specific window
    void Start(HWND hwnd);
    void Stop();

    void SetCallback(Callback cb) { callback_ = cb; }

    /// Call from window proc to process messages
    bool ProcessMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);

    bool IsCapturing() const { return isCapturing_; }
    void SetCapturing(bool v) { isCapturing_ = v; }

private:
    uint32_t GetModifiers() const;

    Callback callback_;
    HWND hwnd_ = nullptr;
    bool isCapturing_ = false;
    UINT windowWidth_ = 1;
    UINT windowHeight_ = 1;
};

} // namespace peariscope
