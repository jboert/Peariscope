#include "InputInjector.h"

namespace peariscope {

InputInjector::InputInjector(UINT displayWidth, UINT displayHeight)
    : displayWidth_(displayWidth), displayHeight_(displayHeight) {}

void InputInjector::InjectKey(uint32_t vkCode, uint32_t modifiers, bool pressed) {
    INPUT input = {};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = static_cast<WORD>(vkCode);
    input.ki.wScan = static_cast<WORD>(MapVirtualKey(vkCode, MAPVK_VK_TO_VSC));
    if (!pressed) input.ki.dwFlags |= KEYEVENTF_KEYUP;

    SendInput(1, &input, sizeof(INPUT));
}

void InputInjector::InjectMouseMove(float normX, float normY) {
    // Convert normalized coords to absolute screen coords (0-65535 range)
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dx = static_cast<LONG>(normX * 65535.0f);
    input.mi.dy = static_cast<LONG>(normY * 65535.0f);
    input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;

    SendInput(1, &input, sizeof(INPUT));
}

void InputInjector::InjectMouseButton(uint32_t button, bool pressed, float normX, float normY) {
    // Move to position first
    InjectMouseMove(normX, normY);

    INPUT input = {};
    input.type = INPUT_MOUSE;

    switch (button) {
    case 0: // Left
        input.mi.dwFlags = pressed ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        break;
    case 1: // Right
        input.mi.dwFlags = pressed ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        break;
    case 2: // Middle
        input.mi.dwFlags = pressed ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        break;
    }

    SendInput(1, &input, sizeof(INPUT));
}

void InputInjector::InjectScroll(float deltaX, float deltaY) {
    if (deltaY != 0.0f) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_WHEEL;
        input.mi.mouseData = static_cast<DWORD>(deltaY * WHEEL_DELTA);
        SendInput(1, &input, sizeof(INPUT));
    }

    if (deltaX != 0.0f) {
        INPUT input = {};
        input.type = INPUT_MOUSE;
        input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
        input.mi.mouseData = static_cast<DWORD>(deltaX * WHEEL_DELTA);
        SendInput(1, &input, sizeof(INPUT));
    }
}

POINT InputInjector::Denormalize(float x, float y) const {
    return {
        static_cast<LONG>(x * displayWidth_),
        static_cast<LONG>(y * displayHeight_)
    };
}

} // namespace peariscope
