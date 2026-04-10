#pragma once
#include <cstdint>

typedef struct _XDisplay Display;

namespace peariscope {

class X11InputInjector {
public:
    X11InputInjector(uint32_t displayWidth, uint32_t displayHeight);
    ~X11InputInjector();

    void InjectKey(uint32_t vkCode, uint32_t modifiers, bool pressed);
    void InjectMouseMove(float normX, float normY);
    void InjectMouseButton(uint32_t button, bool pressed, float normX, float normY);
    void InjectScroll(float deltaX, float deltaY);

private:
    unsigned long VkToKeysym(uint32_t vk) const;
    unsigned long CgKeyCodeToKeysym(uint32_t cgKey) const;

    Display* display_ = nullptr;
    uint32_t displayWidth_;
    uint32_t displayHeight_;
    bool useMacKeycodes_ = false;  // Auto-detected from first key event
};

} // namespace peariscope
