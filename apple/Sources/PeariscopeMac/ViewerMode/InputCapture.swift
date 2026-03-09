import Foundation
import AppKit
import PeariscopeCore

/// Captures local keyboard and mouse events from the viewer window
/// and converts them to InputEvents for transmission to the host.
public final class InputCapture: @unchecked Sendable {
    public var onInputEvent: ((Peariscope_InputEvent) -> Void)?

    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private weak var targetView: NSView?

    /// Whether input capture is active (keyboard/mouse forwarded to remote)
    public var isCapturing = false

    public init() {}

    /// Start capturing input events from the given view
    public func start(in view: NSView) {
        targetView = view
        isCapturing = true

        // Monitor key events when our app is active
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            self.handleKeyEvent(event)
            return nil  // Consume the event (don't pass to local app)
        }

        // Monitor mouse events
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseUp,
                       .rightMouseDown, .rightMouseUp,
                       .otherMouseDown, .otherMouseUp,
                       .leftMouseDragged, .rightMouseDragged,
                       .scrollWheel]
        ) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            guard self.isEventInTargetView(event) else { return event }
            self.handleMouseEvent(event)
            return nil
        }
    }

    /// Stop capturing
    public func stop() {
        isCapturing = false
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    /// Toggle capture on/off
    public func toggle() {
        isCapturing.toggle()
    }

    // MARK: - Key Events

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = convertModifiers(event.modifierFlags)

        if event.type == .flagsChanged {
            // Modifier key change — determine if pressed or released by checking flags
            let keycode = UInt32(event.keyCode)
            let pressed = isModifierPressed(keyCode: event.keyCode, flags: event.modifierFlags)
            let inputEvent = makeKeyEvent(keycode: keycode, modifiers: modifiers, pressed: pressed)
            onInputEvent?(inputEvent)
        } else {
            let pressed = event.type == .keyDown
            let inputEvent = makeKeyEvent(
                keycode: UInt32(event.keyCode),
                modifiers: modifiers,
                pressed: pressed
            )
            onInputEvent?(inputEvent)
        }
    }

    // MARK: - Mouse Events

    private func handleMouseEvent(_ event: NSEvent) {
        guard let targetView else { return }

        // Convert to normalized coordinates relative to the view
        let locationInView = targetView.convert(event.locationInWindow, from: nil)
        let bounds = targetView.bounds
        let nx = Float(locationInView.x / bounds.width)
        // Flip Y (AppKit is bottom-left origin, screen is top-left)
        let ny = Float(1.0 - locationInView.y / bounds.height)

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let inputEvent = makeMouseMoveEvent(x: nx, y: ny)
            onInputEvent?(inputEvent)

        case .leftMouseDown:
            let inputEvent = makeMouseButtonEvent(button: .left, pressed: true, x: nx, y: ny)
            onInputEvent?(inputEvent)
        case .leftMouseUp:
            let inputEvent = makeMouseButtonEvent(button: .left, pressed: false, x: nx, y: ny)
            onInputEvent?(inputEvent)

        case .rightMouseDown:
            let inputEvent = makeMouseButtonEvent(button: .right, pressed: true, x: nx, y: ny)
            onInputEvent?(inputEvent)
        case .rightMouseUp:
            let inputEvent = makeMouseButtonEvent(button: .right, pressed: false, x: nx, y: ny)
            onInputEvent?(inputEvent)

        case .otherMouseDown:
            let inputEvent = makeMouseButtonEvent(button: .middle, pressed: true, x: nx, y: ny)
            onInputEvent?(inputEvent)
        case .otherMouseUp:
            let inputEvent = makeMouseButtonEvent(button: .middle, pressed: false, x: nx, y: ny)
            onInputEvent?(inputEvent)

        case .scrollWheel:
            let inputEvent = makeScrollEvent(
                deltaX: Float(event.scrollingDeltaX),
                deltaY: Float(event.scrollingDeltaY)
            )
            onInputEvent?(inputEvent)

        default:
            break
        }
    }

    // MARK: - Helpers

    private func isEventInTargetView(_ event: NSEvent) -> Bool {
        guard let targetView, let window = targetView.window else { return false }
        guard event.window === window else { return false }
        let locationInView = targetView.convert(event.locationInWindow, from: nil)
        return targetView.bounds.contains(locationInView)
    }

    private func convertModifiers(_ flags: NSEvent.ModifierFlags) -> InputModifiers {
        var modifiers = InputModifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.meta) }
        return modifiers
    }

    private func isModifierPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 56, 60: return flags.contains(.shift)      // Left/Right Shift
        case 59, 62: return flags.contains(.control)    // Left/Right Control
        case 58, 61: return flags.contains(.option)     // Left/Right Option
        case 55, 54: return flags.contains(.command)    // Left/Right Command
        case 57:     return flags.contains(.capsLock)   // Caps Lock
        default:     return false
        }
    }
}
