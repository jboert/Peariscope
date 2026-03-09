#pragma once

#include <Windows.h>
#include <cstdint>

namespace peariscope {

/// Injects input events into the local Windows session using SendInput.
class InputInjector {
public:
    InputInjector(UINT displayWidth, UINT displayHeight);

    void InjectKey(uint32_t vkCode, uint32_t modifiers, bool pressed);
    void InjectMouseMove(float normX, float normY);
    void InjectMouseButton(uint32_t button, bool pressed, float normX, float normY);
    void InjectScroll(float deltaX, float deltaY);

private:
    void SetModifiers(uint32_t modifiers, bool press);
    POINT Denormalize(float x, float y) const;

    UINT displayWidth_;
    UINT displayHeight_;
};

} // namespace peariscope
