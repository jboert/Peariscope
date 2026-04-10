#include "X11InputInjector.h"

#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>

#include <cmath>
#include <iostream>

namespace peariscope {

X11InputInjector::X11InputInjector(uint32_t displayWidth, uint32_t displayHeight)
    : displayWidth_(displayWidth), displayHeight_(displayHeight) {
    display_ = XOpenDisplay(nullptr);
}

X11InputInjector::~X11InputInjector() {
    if (display_) {
        XCloseDisplay(display_);
        display_ = nullptr;
    }
}

void X11InputInjector::InjectKey(uint32_t vkCode, uint32_t modifiers, bool pressed) {
    if (!display_)
        return;

    unsigned long keysym = NoSymbol;

    // Auto-detect Mac keycodes: VK code 0 is unused on Windows,
    // but CGKeyCode 0 = 'A' (a very common first keypress)
    if (!useMacKeycodes_ && vkCode == 0) {
        useMacKeycodes_ = true;
        std::cerr << "[InputInjector] Detected macOS CGKeyCodes — switching to Mac keymap" << std::endl;
    }

    if (useMacKeycodes_) {
        keysym = CgKeyCodeToKeysym(vkCode);
    } else {
        keysym = VkToKeysym(vkCode);
    }

    if (keysym == NoSymbol)
        return;

    KeyCode keycode = XKeysymToKeycode(display_, keysym);
    if (keycode == 0)
        return;

    XTestFakeKeyEvent(display_, keycode, pressed ? True : False, CurrentTime);
    XFlush(display_);
}

void X11InputInjector::InjectMouseMove(float normX, float normY) {
    if (!display_)
        return;

    int x = static_cast<int>(normX * static_cast<float>(displayWidth_));
    int y = static_cast<int>(normY * static_cast<float>(displayHeight_));

    // Clamp to display bounds
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= static_cast<int>(displayWidth_)) x = static_cast<int>(displayWidth_) - 1;
    if (y >= static_cast<int>(displayHeight_)) y = static_cast<int>(displayHeight_) - 1;

    XTestFakeMotionEvent(display_, DefaultScreen(display_), x, y, CurrentTime);
    XFlush(display_);
}

void X11InputInjector::InjectMouseButton(uint32_t button, bool pressed, float normX, float normY) {
    if (!display_)
        return;

    // Move to position first
    InjectMouseMove(normX, normY);

    // Map protocol button to X11 button
    unsigned int x11Button;
    switch (button) {
    case 0: x11Button = 1; break; // Left
    case 1: x11Button = 3; break; // Right
    case 2: x11Button = 2; break; // Middle
    default: return;
    }

    XTestFakeButtonEvent(display_, x11Button, pressed ? True : False, CurrentTime);
    XFlush(display_);
}

void X11InputInjector::InjectScroll(float deltaX, float deltaY) {
    if (!display_)
        return;

    // Vertical scroll
    if (deltaY != 0.0f) {
        unsigned int button = (deltaY > 0.0f) ? 4 : 5;
        int clicks = static_cast<int>(std::abs(deltaY));
        if (clicks < 1) clicks = 1;
        for (int i = 0; i < clicks; ++i) {
            XTestFakeButtonEvent(display_, button, True, CurrentTime);
            XTestFakeButtonEvent(display_, button, False, CurrentTime);
        }
    }

    // Horizontal scroll
    if (deltaX != 0.0f) {
        unsigned int button = (deltaX > 0.0f) ? 7 : 6;
        int clicks = static_cast<int>(std::abs(deltaX));
        if (clicks < 1) clicks = 1;
        for (int i = 0; i < clicks; ++i) {
            XTestFakeButtonEvent(display_, button, True, CurrentTime);
            XTestFakeButtonEvent(display_, button, False, CurrentTime);
        }
    }

    XFlush(display_);
}

// macOS CGKeyCode -> X11 keysym mapping
unsigned long X11InputInjector::CgKeyCodeToKeysym(uint32_t cgKey) const {
    switch (cgKey) {
    // Letters (macOS layout order, NOT alphabetical)
    case 0:  return XK_a;
    case 1:  return XK_s;
    case 2:  return XK_d;
    case 3:  return XK_f;
    case 4:  return XK_h;
    case 5:  return XK_g;
    case 6:  return XK_z;
    case 7:  return XK_x;
    case 8:  return XK_c;
    case 9:  return XK_v;
    case 10: return XK_section;  // ISO keyboard § key
    case 11: return XK_b;
    case 12: return XK_q;
    case 13: return XK_w;
    case 14: return XK_e;
    case 15: return XK_r;
    case 16: return XK_y;
    case 17: return XK_t;
    case 18: return XK_1;
    case 19: return XK_2;
    case 20: return XK_3;
    case 21: return XK_4;
    case 22: return XK_6;
    case 23: return XK_5;
    case 24: return XK_equal;
    case 25: return XK_9;
    case 26: return XK_7;
    case 27: return XK_minus;
    case 28: return XK_8;
    case 29: return XK_0;
    case 30: return XK_bracketright;
    case 31: return XK_o;
    case 32: return XK_u;
    case 33: return XK_bracketleft;
    case 34: return XK_i;
    case 35: return XK_p;
    case 37: return XK_l;
    case 38: return XK_j;
    case 39: return XK_apostrophe;
    case 40: return XK_k;
    case 41: return XK_semicolon;
    case 42: return XK_backslash;
    case 43: return XK_comma;
    case 44: return XK_slash;
    case 45: return XK_n;
    case 46: return XK_m;
    case 47: return XK_period;
    case 50: return XK_grave;

    // Special keys
    case 36: return XK_Return;
    case 48: return XK_Tab;
    case 49: return XK_space;
    case 51: return XK_BackSpace;  // macOS "Delete" = Backspace
    case 53: return XK_Escape;
    case 76: return XK_KP_Enter;   // Numpad Enter

    // Modifier keys
    case 55: return XK_Super_L;    // Command (Left)
    case 54: return XK_Super_R;    // Command (Right)
    case 56: return XK_Shift_L;
    case 57: return XK_Caps_Lock;
    case 58: return XK_Alt_L;      // Option (Left)
    case 59: return XK_Control_L;
    case 60: return XK_Shift_R;
    case 61: return XK_Alt_R;      // Option (Right)
    case 62: return XK_Control_R;
    case 63: return XK_Meta_L;     // fn key

    // Function keys
    case 122: return XK_F1;
    case 120: return XK_F2;
    case 99:  return XK_F3;
    case 118: return XK_F4;
    case 96:  return XK_F5;
    case 97:  return XK_F6;
    case 98:  return XK_F7;
    case 100: return XK_F8;
    case 101: return XK_F9;
    case 109: return XK_F10;
    case 103: return XK_F11;
    case 111: return XK_F12;

    // Navigation
    case 115: return XK_Home;
    case 119: return XK_End;
    case 116: return XK_Page_Up;
    case 121: return XK_Page_Down;
    case 117: return XK_Delete;    // macOS "Forward Delete"

    // Arrow keys
    case 123: return XK_Left;
    case 124: return XK_Right;
    case 125: return XK_Down;
    case 126: return XK_Up;

    // Numpad
    case 65: return XK_KP_Decimal;
    case 67: return XK_KP_Multiply;
    case 69: return XK_KP_Add;
    case 71: return XK_Num_Lock;   // Clear on Mac
    case 75: return XK_KP_Divide;
    case 78: return XK_KP_Subtract;
    case 81: return XK_KP_Equal;
    case 82: return XK_KP_0;
    case 83: return XK_KP_1;
    case 84: return XK_KP_2;
    case 85: return XK_KP_3;
    case 86: return XK_KP_4;
    case 87: return XK_KP_5;
    case 88: return XK_KP_6;
    case 89: return XK_KP_7;
    case 91: return XK_KP_8;
    case 92: return XK_KP_9;

    default: return NoSymbol;
    }
}

unsigned long X11InputInjector::VkToKeysym(uint32_t vk) const {
    // Letters VK 0x41-0x5A -> XK_a-XK_z (lowercase)
    if (vk >= 0x41 && vk <= 0x5A)
        return XK_a + (vk - 0x41);

    // Digits VK 0x30-0x39 -> XK_0-XK_9
    if (vk >= 0x30 && vk <= 0x39)
        return XK_0 + (vk - 0x30);

    // Function keys VK 0x70-0x7B -> XK_F1-XK_F12
    if (vk >= 0x70 && vk <= 0x7B)
        return XK_F1 + (vk - 0x70);

    switch (vk) {
    case 0x08: return XK_BackSpace;
    case 0x09: return XK_Tab;
    case 0x0D: return XK_Return;
    case 0x10: return XK_Shift_L;    // VK_SHIFT
    case 0x11: return XK_Control_L;  // VK_CONTROL
    case 0x12: return XK_Alt_L;      // VK_MENU
    case 0x13: return XK_Pause;
    case 0x14: return XK_Caps_Lock;
    case 0x1B: return XK_Escape;
    case 0x20: return XK_space;
    case 0x21: return XK_Page_Up;
    case 0x22: return XK_Page_Down;
    case 0x23: return XK_End;
    case 0x24: return XK_Home;
    case 0x25: return XK_Left;
    case 0x26: return XK_Up;
    case 0x27: return XK_Right;
    case 0x28: return XK_Down;
    case 0x2C: return XK_Print;      // VK_SNAPSHOT
    case 0x2D: return XK_Insert;
    case 0x2E: return XK_Delete;
    case 0x5B: return XK_Super_L;    // VK_LWIN
    case 0x5C: return XK_Super_R;    // VK_RWIN
    case 0x90: return XK_Num_Lock;
    case 0x91: return XK_Scroll_Lock;
    case 0xBA: return XK_semicolon;  // VK_OEM_1
    case 0xBB: return XK_equal;      // VK_OEM_PLUS
    case 0xBC: return XK_comma;      // VK_OEM_COMMA
    case 0xBD: return XK_minus;      // VK_OEM_MINUS
    case 0xBE: return XK_period;     // VK_OEM_PERIOD
    case 0xBF: return XK_slash;      // VK_OEM_2
    case 0xC0: return XK_grave;      // VK_OEM_3
    case 0xDB: return XK_bracketleft;  // VK_OEM_4
    case 0xDC: return XK_backslash;    // VK_OEM_5
    case 0xDD: return XK_bracketright; // VK_OEM_6
    case 0xDE: return XK_apostrophe;   // VK_OEM_7
    default:   return NoSymbol;
    }
}

} // namespace peariscope
