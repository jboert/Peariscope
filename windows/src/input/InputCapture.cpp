#include "InputCapture.h"
#include <windowsx.h>

namespace peariscope {

InputCapture::InputCapture() = default;
InputCapture::~InputCapture() { Stop(); }

void InputCapture::Start(HWND hwnd) {
    hwnd_ = hwnd;
    isCapturing_ = true;

    RECT rect;
    GetClientRect(hwnd, &rect);
    windowWidth_ = rect.right - rect.left;
    windowHeight_ = rect.bottom - rect.top;
}

void InputCapture::Stop() {
    isCapturing_ = false;
    hwnd_ = nullptr;
}

bool InputCapture::ProcessMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (!isCapturing_ || !callback_) return false;

    InputEvent event;
    float mx = static_cast<float>(GET_X_LPARAM(lParam)) / windowWidth_;
    float my = static_cast<float>(GET_Y_LPARAM(lParam)) / windowHeight_;

    switch (msg) {
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        event.type = InputEvent::KEY;
        event.keycode = static_cast<uint32_t>(wParam);
        event.modifiers = GetModifiers();
        event.pressed = true;
        callback_(event);
        return true;

    case WM_KEYUP:
    case WM_SYSKEYUP:
        event.type = InputEvent::KEY;
        event.keycode = static_cast<uint32_t>(wParam);
        event.modifiers = GetModifiers();
        event.pressed = false;
        callback_(event);
        return true;

    case WM_MOUSEMOVE:
        event.type = InputEvent::MOUSE_MOVE;
        event.x = mx;
        event.y = my;
        callback_(event);
        return true;

    case WM_LBUTTONDOWN:
        event.type = InputEvent::MOUSE_BUTTON;
        event.button = 0;
        event.pressed = true;
        event.x = mx; event.y = my;
        callback_(event);
        return true;

    case WM_LBUTTONUP:
        event.type = InputEvent::MOUSE_BUTTON;
        event.button = 0;
        event.pressed = false;
        event.x = mx; event.y = my;
        callback_(event);
        return true;

    case WM_RBUTTONDOWN:
        event.type = InputEvent::MOUSE_BUTTON;
        event.button = 1;
        event.pressed = true;
        event.x = mx; event.y = my;
        callback_(event);
        return true;

    case WM_RBUTTONUP:
        event.type = InputEvent::MOUSE_BUTTON;
        event.button = 1;
        event.pressed = false;
        event.x = mx; event.y = my;
        callback_(event);
        return true;

    case WM_MBUTTONDOWN:
        event.type = InputEvent::MOUSE_BUTTON;
        event.button = 2;
        event.pressed = true;
        event.x = mx; event.y = my;
        callback_(event);
        return true;

    case WM_MBUTTONUP:
        event.type = InputEvent::MOUSE_BUTTON;
        event.button = 2;
        event.pressed = false;
        event.x = mx; event.y = my;
        callback_(event);
        return true;

    case WM_MOUSEWHEEL:
        event.type = InputEvent::SCROLL;
        event.scrollDeltaY = static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
        callback_(event);
        return true;

    case WM_MOUSEHWHEEL:
        event.type = InputEvent::SCROLL;
        event.scrollDeltaX = static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
        callback_(event);
        return true;

    case WM_SIZE:
        windowWidth_ = LOWORD(lParam);
        windowHeight_ = HIWORD(lParam);
        if (windowWidth_ == 0) windowWidth_ = 1;
        if (windowHeight_ == 0) windowHeight_ = 1;
        return false;  // Don't consume resize
    }

    return false;
}

uint32_t InputCapture::GetModifiers() const {
    uint32_t mods = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000)   mods |= 1;
    if (GetKeyState(VK_CONTROL) & 0x8000) mods |= 2;
    if (GetKeyState(VK_MENU) & 0x8000)    mods |= 4;  // Alt
    if (GetKeyState(VK_LWIN) & 0x8000 || GetKeyState(VK_RWIN) & 0x8000) mods |= 8;
    return mods;
}

} // namespace peariscope
