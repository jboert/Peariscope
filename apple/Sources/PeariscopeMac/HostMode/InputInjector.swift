import Foundation
import CoreGraphics
import ApplicationServices
import PeariscopeCore

/// Injects remote input events into the local macOS session using CGEvent.
/// Requires Accessibility permissions (System Settings > Privacy > Accessibility).
public final class InputInjector: @unchecked Sendable {
    private let displaySize: CGSize
    private var lastMousePosition: CGPoint = .zero

    public init(displayWidth: Int, displayHeight: Int) {
        self.displaySize = CGSize(width: displayWidth, height: displayHeight)
    }

    /// Check if we have Accessibility permissions
    public nonisolated static var hasAccessibilityPermission: Bool {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        )
    }

    /// Prompt user for Accessibility permissions
    @discardableResult
    public nonisolated static func requestAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    /// Process a received input event from a remote viewer
    public func inject(_ event: Peariscope_InputEvent) {
        switch event.event {
        case .key(let key):
            injectKey(key)
        case .mouseMove(let move):
            injectMouseMove(move)
        case .mouseButton(let button):
            injectMouseButton(button)
        case .scroll(let scroll):
            injectScroll(scroll)
        case .none:
            break
        }
    }

    // MARK: - Keyboard

    private func injectKey(_ key: Peariscope_KeyEvent) {
        // Check for virtual keycode marker (0x80000000 in modifiers)
        if key.modifiers & 0x80000000 != 0 {
            // Raw CGKeyCode (backspace=51, return=36, tab=48, etc.)
            guard let event = CGEvent(keyboardEventSource: nil,
                                       virtualKey: CGKeyCode(key.keycode),
                                       keyDown: key.pressed) else { return }
            let realModifiers = key.modifiers & 0x7FFFFFFF
            if realModifiers != 0 {
                applyModifiers(event, modifiers: realModifiers)
            }
            event.post(tap: .cghidEventTap)
        } else {
            // Unicode character from iOS keyboard
            injectCharacter(key)
        }
    }

    /// Inject a character by creating a keyboard event with Unicode string
    private func injectCharacter(_ key: Peariscope_KeyEvent) {
        // Use virtual key 0 as placeholder — the Unicode string is what matters
        guard let event = CGEvent(keyboardEventSource: nil,
                                   virtualKey: 0,
                                   keyDown: key.pressed) else { return }
        if let scalar = Unicode.Scalar(key.keycode) {
            let char = Character(scalar)
            var utf16 = Array(String(char).utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Move

    private func injectMouseMove(_ move: Peariscope_MouseMoveEvent) {
        let point = denormalize(x: move.x, y: move.y)
        lastMousePosition = point

        guard let event = CGEvent(mouseEventSource: nil,
                                   mouseType: .mouseMoved,
                                   mouseCursorPosition: point,
                                   mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Button

    private func injectMouseButton(_ btn: Peariscope_MouseButtonEvent) {
        let point = denormalize(x: btn.x, y: btn.y)
        lastMousePosition = point

        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch btn.button {
        case 0: // left
            mouseButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        case 1: // right
            mouseButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        case 2: // middle
            mouseButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
        default:
            return
        }

        let eventType = btn.pressed ? downType : upType

        guard let event = CGEvent(mouseEventSource: nil,
                                   mouseType: eventType,
                                   mouseCursorPosition: point,
                                   mouseButton: mouseButton) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    private func injectScroll(_ scroll: Peariscope_ScrollEvent) {
        let maxDelta: Float = 1000
        guard scroll.deltaX.isFinite, scroll.deltaY.isFinite else { return }
        let dx = min(max(scroll.deltaX, -maxDelta), maxDelta)
        let dy = min(max(scroll.deltaY, -maxDelta), maxDelta)
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                   units: .pixel,
                                   wheelCount: 2,
                                   wheel1: Int32(dy),
                                   wheel2: Int32(dx),
                                   wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    /// Convert normalized coordinates (0.0-1.0) to screen pixel coordinates
    private func denormalize(x: Float, y: Float) -> CGPoint {
        guard x.isFinite, y.isFinite else { return lastMousePosition }
        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        return CGPoint(
            x: CGFloat(clampedX) * displaySize.width,
            y: CGFloat(clampedY) * displaySize.height
        )
    }

    /// Apply modifier flags to a CGEvent
    private func applyModifiers(_ event: CGEvent, modifiers: UInt32) {
        var flags = CGEventFlags()
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskControl) }
        if modifiers & 4 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 8 != 0 { flags.insert(.maskCommand) }
        event.flags = flags
    }
}
