import Foundation

/// Platform-neutral virtual keycodes based on X11 keysyms.
/// Used in the KeyEvent protobuf when modifiers has the 0x80000000 marker.
/// X11 keysyms are the standard because:
/// - For ASCII characters, keysym == Unicode code point (so no mapping needed)
/// - Every platform has well-defined mappings from X11 keysyms
/// - Linux hosts can use them directly with xdotool/xkbcommon
public enum VK: UInt32 {
    // Navigation
    case home       = 0xFF50
    case left       = 0xFF51
    case up         = 0xFF52
    case right      = 0xFF53
    case down       = 0xFF54
    case pageUp     = 0xFF55
    case pageDown   = 0xFF56
    case end        = 0xFF57

    // Editing
    case backspace  = 0xFF08
    case tab        = 0xFF09
    case `return`   = 0xFF0D
    case escape     = 0xFF1B
    case delete     = 0xFFFF
    case space      = 0x0020  // Same as Unicode/ASCII

    // Function keys
    case f1         = 0xFFBE
    case f2         = 0xFFBF
    case f3         = 0xFFC0
    case f4         = 0xFFC1
    case f5         = 0xFFC2
    case f6         = 0xFFC3
    case f7         = 0xFFC4
    case f8         = 0xFFC5
    case f9         = 0xFFC6
    case f10        = 0xFFC7
    case f11        = 0xFFC8
    case f12        = 0xFFC9

    // Letters (lowercase ASCII = X11 keysym = Unicode)
    case a = 0x61, b = 0x62, c = 0x63, d = 0x64, e = 0x65
    case f = 0x66, g = 0x67, h = 0x68, i = 0x69, j = 0x6A
    case k = 0x6B, l = 0x6C, m = 0x6D, n = 0x6E, o = 0x6F
    case p = 0x70, q = 0x71, r = 0x72, s = 0x73, t = 0x74
    case u = 0x75, v = 0x76, w = 0x77, x = 0x78, y = 0x79
    case z = 0x7A

    // Digits
    case d0 = 0x30, d1 = 0x31, d2 = 0x32, d3 = 0x33, d4 = 0x34
    case d5 = 0x35, d6 = 0x36, d7 = 0x37, d8 = 0x38, d9 = 0x39

    // Symbols
    case minus       = 0x2D  // -
    case equal       = 0x3D  // =
    case bracketLeft = 0x5B  // [
    case bracketRight = 0x5D // ]
    case backslash   = 0x5C  // \.
    case semicolon   = 0x3B  // ;
    case apostrophe  = 0x27  // '
    case comma       = 0x2C  // ,
    case period      = 0x2E  // .
    case slash       = 0x2F  // /
    case grave       = 0x60  // `
}

/// Map X11 keysym → macOS CGKeyCode.
/// Used by InputInjector on the macOS host to translate incoming virtual keycodes.
public let xkToCGKeyCode: [UInt32: UInt16] = [
    // Navigation
    VK.home.rawValue:      115,
    VK.left.rawValue:      123,
    VK.up.rawValue:        126,
    VK.right.rawValue:     124,
    VK.down.rawValue:      125,
    VK.pageUp.rawValue:    116,
    VK.pageDown.rawValue:  121,
    VK.end.rawValue:       119,

    // Editing
    VK.backspace.rawValue: 51,
    VK.tab.rawValue:       48,
    VK.return.rawValue:    36,
    VK.escape.rawValue:    53,
    VK.delete.rawValue:    117,
    VK.space.rawValue:     49,

    // Function keys
    VK.f1.rawValue:  122, VK.f2.rawValue:  120, VK.f3.rawValue:  99,
    VK.f4.rawValue:  118, VK.f5.rawValue:  96,  VK.f6.rawValue:  97,
    VK.f7.rawValue:  98,  VK.f8.rawValue:  100, VK.f9.rawValue:  101,
    VK.f10.rawValue: 109, VK.f11.rawValue: 103, VK.f12.rawValue: 111,

    // Letters (X11 keysym → CGKeyCode)
    VK.a.rawValue: 0,  VK.b.rawValue: 11, VK.c.rawValue: 8,
    VK.d.rawValue: 2,  VK.e.rawValue: 14, VK.f.rawValue: 3,
    VK.g.rawValue: 5,  VK.h.rawValue: 4,  VK.i.rawValue: 34,
    VK.j.rawValue: 38, VK.k.rawValue: 40, VK.l.rawValue: 37,
    VK.m.rawValue: 46, VK.n.rawValue: 45, VK.o.rawValue: 31,
    VK.p.rawValue: 35, VK.q.rawValue: 12, VK.r.rawValue: 15,
    VK.s.rawValue: 1,  VK.t.rawValue: 17, VK.u.rawValue: 32,
    VK.v.rawValue: 9,  VK.w.rawValue: 13, VK.x.rawValue: 7,
    VK.y.rawValue: 16, VK.z.rawValue: 6,

    // Digits
    VK.d0.rawValue: 29, VK.d1.rawValue: 18, VK.d2.rawValue: 19,
    VK.d3.rawValue: 20, VK.d4.rawValue: 21, VK.d5.rawValue: 23,
    VK.d6.rawValue: 22, VK.d7.rawValue: 26, VK.d8.rawValue: 28,
    VK.d9.rawValue: 25,

    // Symbols
    VK.minus.rawValue:        27, VK.equal.rawValue:       24,
    VK.bracketLeft.rawValue:  33, VK.bracketRight.rawValue: 30,
    VK.backslash.rawValue:    42, VK.semicolon.rawValue:    41,
    VK.apostrophe.rawValue:   39, VK.comma.rawValue:        43,
    VK.period.rawValue:       47, VK.slash.rawValue:        44,
    VK.grave.rawValue:        50,
]

/// Reverse map: macOS CGKeyCode → X11 keysym.
/// Used by macOS viewer (InputCapture) to convert captured CGKeyCodes
/// to platform-neutral keysyms before sending to the host.
public let cgKeyCodeToXK: [UInt16: UInt32] = {
    var map: [UInt16: UInt32] = [:]
    for (xk, cg) in xkToCGKeyCode {
        map[cg] = xk
    }
    return map
}()
