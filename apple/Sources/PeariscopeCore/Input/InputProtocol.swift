import Foundation
import SwiftProtobuf

/// Platform-neutral input event types that get serialized as protobuf
/// and sent over the Pear stream's INPUT channel.

/// Encode an InputEvent to Data for network transmission
public func encodeInputEvent(_ event: Peariscope_InputEvent) -> Data? {
    return try? event.serializedData()
}

/// Decode an InputEvent from network Data
public func decodeInputEvent(_ data: Data) -> Peariscope_InputEvent? {
    return try? Peariscope_InputEvent(serializedBytes: data)
}

/// Modifier key bitmask values (cross-platform)
public struct InputModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift   = InputModifiers(rawValue: 1)
    public static let control = InputModifiers(rawValue: 2)
    public static let alt     = InputModifiers(rawValue: 4)
    public static let meta    = InputModifiers(rawValue: 8)  // Cmd on mac, Win on windows
}

/// Mouse button identifiers
public enum MouseButton: UInt32, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - Convenience builders

public func makeKeyEvent(keycode: UInt32, modifiers: InputModifiers, pressed: Bool) -> Peariscope_InputEvent {
    var event = Peariscope_InputEvent()
    event.timestampMs = UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    var key = Peariscope_KeyEvent()
    key.keycode = keycode
    key.modifiers = modifiers.rawValue
    key.pressed = pressed
    event.key = key
    return event
}

public func makeMouseMoveEvent(x: Float, y: Float) -> Peariscope_InputEvent {
    var event = Peariscope_InputEvent()
    event.timestampMs = UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    var move = Peariscope_MouseMoveEvent()
    move.x = x
    move.y = y
    event.mouseMove = move
    return event
}

public func makeMouseButtonEvent(button: MouseButton, pressed: Bool, x: Float, y: Float) -> Peariscope_InputEvent {
    var event = Peariscope_InputEvent()
    event.timestampMs = UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    var btn = Peariscope_MouseButtonEvent()
    btn.button = button.rawValue
    btn.pressed = pressed
    btn.x = x
    btn.y = y
    event.mouseButton = btn
    return event
}

public func makeScrollEvent(deltaX: Float, deltaY: Float) -> Peariscope_InputEvent {
    var event = Peariscope_InputEvent()
    event.timestampMs = UInt32(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    var scroll = Peariscope_ScrollEvent()
    scroll.deltaX = deltaX
    scroll.deltaY = deltaY
    event.scroll = scroll
    return event
}
