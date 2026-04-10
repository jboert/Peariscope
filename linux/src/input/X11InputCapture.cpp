#include "X11InputCapture.h"

#include <X11/Xlib.h>
#include <X11/keysym.h>

namespace peariscope {

X11InputCapture::X11InputCapture() = default;

X11InputCapture::~X11InputCapture() {
    Stop();
}

void X11InputCapture::Start(Display* display, Window window) {
    display_ = display;
    window_ = window;
    isCapturing_ = true;

    // Query window dimensions for normalization
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display_, window_, &attrs)) {
        windowWidth_ = static_cast<uint32_t>(attrs.width);
        windowHeight_ = static_cast<uint32_t>(attrs.height);
        if (windowWidth_ == 0) windowWidth_ = 1;
        if (windowHeight_ == 0) windowHeight_ = 1;
    }
}

void X11InputCapture::Stop() {
    isCapturing_ = false;
    display_ = nullptr;
    window_ = 0;
}

bool X11InputCapture::ProcessEvent(void* xevent) {
    if (!isCapturing_ || !callback_)
        return false;

    auto* ev = static_cast<XEvent*>(xevent);

    switch (ev->type) {
    case KeyPress:
    case KeyRelease: {
        auto& key = ev->xkey;
        KeySym keysym = XLookupKeysym(&key, 0);
        InputEvent ie;
        ie.type = InputEvent::KEY;
        ie.keycode = X11KeysymToVk(keysym);
        ie.modifiers = GetModifiers(key.state);
        ie.pressed = (ev->type == KeyPress);
        if (ie.keycode != 0) {
            callback_(ie);
            return true;
        }
        break;
    }

    case MotionNotify: {
        auto& motion = ev->xmotion;
        InputEvent ie;
        ie.type = InputEvent::MOUSE_MOVE;
        ie.x = static_cast<float>(motion.x) / static_cast<float>(windowWidth_);
        ie.y = static_cast<float>(motion.y) / static_cast<float>(windowHeight_);
        ie.modifiers = GetModifiers(motion.state);
        callback_(ie);
        return true;
    }

    case ButtonPress:
    case ButtonRelease: {
        auto& btn = ev->xbutton;
        bool pressed = (ev->type == ButtonPress);

        // Scroll wheel events (buttons 4-7)
        if (btn.button >= 4 && btn.button <= 7 && pressed) {
            InputEvent ie;
            ie.type = InputEvent::SCROLL;
            ie.x = static_cast<float>(btn.x) / static_cast<float>(windowWidth_);
            ie.y = static_cast<float>(btn.y) / static_cast<float>(windowHeight_);
            ie.modifiers = GetModifiers(btn.state);
            switch (btn.button) {
            case 4: ie.scrollDeltaY = 1.0f; break;
            case 5: ie.scrollDeltaY = -1.0f; break;
            case 6: ie.scrollDeltaX = -1.0f; break;
            case 7: ie.scrollDeltaX = 1.0f; break;
            }
            callback_(ie);
            return true;
        }

        // Regular mouse buttons
        InputEvent ie;
        ie.type = InputEvent::MOUSE_BUTTON;
        ie.pressed = pressed;
        ie.x = static_cast<float>(btn.x) / static_cast<float>(windowWidth_);
        ie.y = static_cast<float>(btn.y) / static_cast<float>(windowHeight_);
        ie.modifiers = GetModifiers(btn.state);

        switch (btn.button) {
        case 1: ie.button = 0; break; // Left
        case 3: ie.button = 1; break; // Right
        case 2: ie.button = 2; break; // Middle
        default: return false;
        }

        callback_(ie);
        return true;
    }

    default:
        break;
    }

    return false;
}

uint32_t X11InputCapture::X11KeysymToVk(unsigned long keysym) const {
    // Letters a-z -> VK 0x41-0x5A
    if (keysym >= XK_a && keysym <= XK_z)
        return 0x41 + static_cast<uint32_t>(keysym - XK_a);
    if (keysym >= XK_A && keysym <= XK_Z)
        return 0x41 + static_cast<uint32_t>(keysym - XK_A);

    // Digits 0-9 -> VK 0x30-0x39
    if (keysym >= XK_0 && keysym <= XK_9)
        return 0x30 + static_cast<uint32_t>(keysym - XK_0);

    // Function keys F1-F12 -> VK 0x70-0x7B
    if (keysym >= XK_F1 && keysym <= XK_F12)
        return 0x70 + static_cast<uint32_t>(keysym - XK_F1);

    switch (keysym) {
    case XK_Return:     return 0x0D;
    case XK_Escape:     return 0x1B;
    case XK_space:      return 0x20;
    case XK_BackSpace:  return 0x08;
    case XK_Tab:        return 0x09;
    case XK_Delete:     return 0x2E;
    case XK_Insert:     return 0x2D;
    case XK_Home:       return 0x24;
    case XK_End:        return 0x23;
    case XK_Page_Up:    return 0x21;
    case XK_Page_Down:  return 0x22;
    case XK_Left:       return 0x25;
    case XK_Up:         return 0x26;
    case XK_Right:      return 0x27;
    case XK_Down:       return 0x28;
    case XK_Shift_L:
    case XK_Shift_R:    return 0x10; // VK_SHIFT
    case XK_Control_L:
    case XK_Control_R:  return 0x11; // VK_CONTROL
    case XK_Alt_L:
    case XK_Alt_R:      return 0x12; // VK_MENU
    case XK_Super_L:
    case XK_Super_R:    return 0x5B; // VK_LWIN
    case XK_Caps_Lock:  return 0x14;
    case XK_Num_Lock:   return 0x90;
    case XK_Scroll_Lock:return 0x91;
    case XK_Print:      return 0x2C; // VK_SNAPSHOT
    case XK_Pause:      return 0x13;
    case XK_minus:      return 0xBD; // VK_OEM_MINUS
    case XK_equal:      return 0xBB; // VK_OEM_PLUS
    case XK_bracketleft:return 0xDB; // VK_OEM_4
    case XK_bracketright:return 0xDD;// VK_OEM_6
    case XK_backslash:  return 0xDC; // VK_OEM_5
    case XK_semicolon:  return 0xBA; // VK_OEM_1
    case XK_apostrophe: return 0xDE; // VK_OEM_7
    case XK_comma:      return 0xBC; // VK_OEM_COMMA
    case XK_period:     return 0xBE; // VK_OEM_PERIOD
    case XK_slash:      return 0xBF; // VK_OEM_2
    case XK_grave:      return 0xC0; // VK_OEM_3
    default:            return 0;
    }
}

uint32_t X11InputCapture::GetModifiers(unsigned int state) const {
    uint32_t mods = 0;
    if (state & ShiftMask)   mods |= 0x01;
    if (state & ControlMask) mods |= 0x02;
    if (state & Mod1Mask)    mods |= 0x04; // Alt
    if (state & Mod4Mask)    mods |= 0x08; // Super/Win
    return mods;
}

} // namespace peariscope
