#pragma once
#include <functional>
#include <cstdint>

typedef struct _XDisplay Display;
typedef unsigned long Window;

namespace peariscope {

class X11InputCapture {
public:
    struct InputEvent {
        enum Type { KEY, MOUSE_MOVE, MOUSE_BUTTON, SCROLL };
        Type type;
        uint32_t keycode = 0;
        uint32_t modifiers = 0;
        bool pressed = false;
        float x = 0, y = 0;
        uint32_t button = 0;
        float scrollDeltaX = 0, scrollDeltaY = 0;
    };

    using Callback = std::function<void(const InputEvent&)>;

    X11InputCapture();
    ~X11InputCapture();

    void Start(Display* display, Window window);
    void Stop();
    void SetCallback(Callback cb) { callback_ = cb; }

    // Process an X11 event, return true if consumed
    bool ProcessEvent(void* xevent);

    bool IsCapturing() const { return isCapturing_; }
    void SetCapturing(bool v) { isCapturing_ = v; }

private:
    uint32_t X11KeysymToVk(unsigned long keysym) const;
    uint32_t GetModifiers(unsigned int state) const;

    Callback callback_;
    Display* display_ = nullptr;
    Window window_ = 0;
    bool isCapturing_ = false;
    uint32_t windowWidth_ = 1;
    uint32_t windowHeight_ = 1;
};

} // namespace peariscope
