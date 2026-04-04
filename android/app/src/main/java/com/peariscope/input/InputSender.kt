package com.peariscope.input

import android.view.MotionEvent
import com.peariscope.network.NetworkManager

/**
 * Converts Android touch/motion events to protobuf InputEvent messages
 * and sends them via the NetworkManager on channel 1.
 *
 * Trackpad mode: single finger drag moves the cursor (no click). Quick tap = left click.
 * Direct mode: touch position maps directly to screen position, always clicks.
 */
class InputSender(private val networkManager: NetworkManager) {

    private var streamId: Int = 0
    private var lastMouseX = 0.5f
    private var lastMouseY = 0.5f

    // Trackpad mode state — distinguish tap from drag
    private var touchDownTime = 0L
    private var touchDownX = 0f
    private var touchDownY = 0f
    private var hasDragged = false
    private var prevMoveX = 0f
    private var prevMoveY = 0f

    fun setStreamId(id: Int) {
        streamId = id
    }

    fun sendMouseMove(normalizedX: Float, normalizedY: Float) {
        lastMouseX = normalizedX
        lastMouseY = normalizedY

        val mouseMove = com.peariscope.proto.PeariscopeProto.MouseMoveEvent.newBuilder()
            .setX(normalizedX).setY(normalizedY).build()
        val inputEvent = com.peariscope.proto.PeariscopeProto.InputEvent.newBuilder()
            .setTimestampMs(System.currentTimeMillis().toInt())
            .setMouseMove(mouseMove).build()
        sendInputEvent(inputEvent)
    }

    fun sendMouseButton(button: Int, pressed: Boolean, normalizedX: Float, normalizedY: Float) {
        val mouseButton = com.peariscope.proto.PeariscopeProto.MouseButtonEvent.newBuilder()
            .setButton(button).setPressed(pressed)
            .setX(normalizedX).setY(normalizedY).build()
        val inputEvent = com.peariscope.proto.PeariscopeProto.InputEvent.newBuilder()
            .setTimestampMs(System.currentTimeMillis().toInt())
            .setMouseButton(mouseButton).build()
        sendInputEvent(inputEvent)
    }

    fun sendScroll(deltaX: Float, deltaY: Float) {
        val scroll = com.peariscope.proto.PeariscopeProto.ScrollEvent.newBuilder()
            .setDeltaX(deltaX).setDeltaY(deltaY).build()
        val inputEvent = com.peariscope.proto.PeariscopeProto.InputEvent.newBuilder()
            .setTimestampMs(System.currentTimeMillis().toInt())
            .setScroll(scroll).build()
        sendInputEvent(inputEvent)
    }

    /**
     * Process a raw Android MotionEvent.
     *
     * Trackpad mode:
     *   - Drag = move cursor (no click). Relative movement like a laptop trackpad.
     *   - Quick tap (< 200ms, < 20px movement) = left click at cursor position.
     *
     * Direct mode:
     *   - Touch position maps directly to screen position. Always clicks.
     */
    fun handleMotionEvent(
        event: MotionEvent,
        viewWidth: Int,
        viewHeight: Int,
        isTrackpadMode: Boolean
    ) {
        if (viewWidth <= 0 || viewHeight <= 0) return

        val normalizedX = (event.x / viewWidth).coerceIn(0f, 1f)
        val normalizedY = (event.y / viewHeight).coerceIn(0f, 1f)

        if (isTrackpadMode) {
            handleTrackpadMode(event, viewWidth, viewHeight, normalizedX, normalizedY)
        } else {
            handleDirectMode(event, normalizedX, normalizedY)
        }
    }

    private fun handleTrackpadMode(
        event: MotionEvent, viewWidth: Int, viewHeight: Int,
        normalizedX: Float, normalizedY: Float
    ) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touchDownTime = System.currentTimeMillis()
                touchDownX = event.x
                touchDownY = event.y
                hasDragged = false
                // Don't send anything yet — wait to see if it's a tap or drag
            }

            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - touchDownX
                val dy = event.y - touchDownY
                if (!hasDragged && (Math.abs(dx) > TAP_SLOP || Math.abs(dy) > TAP_SLOP)) {
                    hasDragged = true
                    // Initialize previous position for smooth delta tracking
                    prevMoveX = touchDownX / viewWidth
                    prevMoveY = touchDownY / viewHeight
                }

                if (hasDragged) {
                    // Process all historical points for smooth movement
                    val historySize = event.historySize
                    for (i in 0 until historySize) {
                        val hx = event.getHistoricalX(i) / viewWidth
                        val hy = event.getHistoricalY(i) / viewHeight
                        val hdx = hx - prevMoveX
                        val hdy = hy - prevMoveY
                        lastMouseX = (lastMouseX + hdx * TRACKPAD_SENSITIVITY).coerceIn(0f, 1f)
                        lastMouseY = (lastMouseY + hdy * TRACKPAD_SENSITIVITY).coerceIn(0f, 1f)
                        prevMoveX = hx
                        prevMoveY = hy
                    }
                    // Process the current point
                    val cdx = normalizedX - prevMoveX
                    val cdy = normalizedY - prevMoveY
                    lastMouseX = (lastMouseX + cdx * TRACKPAD_SENSITIVITY).coerceIn(0f, 1f)
                    lastMouseY = (lastMouseY + cdy * TRACKPAD_SENSITIVITY).coerceIn(0f, 1f)
                    prevMoveX = normalizedX
                    prevMoveY = normalizedY

                    sendMouseMove(lastMouseX, lastMouseY)
                }
            }

            MotionEvent.ACTION_UP -> {
                val elapsed = System.currentTimeMillis() - touchDownTime
                if (!hasDragged && elapsed < TAP_TIMEOUT_MS) {
                    // Quick tap = left click at current cursor position
                    sendMouseButton(0, true, lastMouseX, lastMouseY)
                    sendMouseButton(0, false, lastMouseX, lastMouseY)
                }
                // If was dragging, just stop — no click
            }
        }
    }

    private fun handleDirectMode(event: MotionEvent, normalizedX: Float, normalizedY: Float) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                sendMouseMove(normalizedX, normalizedY)
                sendMouseButton(0, true, normalizedX, normalizedY)
            }
            MotionEvent.ACTION_MOVE -> {
                sendMouseMove(normalizedX, normalizedY)
            }
            MotionEvent.ACTION_UP -> {
                sendMouseButton(0, false, normalizedX, normalizedY)
            }
        }
    }

    /**
     * Send a key event (press or release).
     * For virtual keys (arrows, F-keys, etc.), set the 0x80000000 flag in modifiers
     * to tell the host this is a raw CGKeyCode, not a Unicode codepoint.
     */
    fun sendKeyEvent(keycode: Int, modifiers: Int, pressed: Boolean) {
        val keyEvent = com.peariscope.proto.PeariscopeProto.KeyEvent.newBuilder()
            .setKeycode(keycode).setModifiers(modifiers).setPressed(pressed).build()
        val inputEvent = com.peariscope.proto.PeariscopeProto.InputEvent.newBuilder()
            .setTimestampMs(System.currentTimeMillis().toInt())
            .setKey(keyEvent).build()
        sendInputEvent(inputEvent)
    }

    /** Send a virtual key tap (down + up) using macOS CGKeyCode with the 0x80000000 marker. */
    fun sendVirtualKey(keycode: Int, modifiers: Int = 0) {
        val mods = CGKEYCODE_FLAG or modifiers
        sendKeyEvent(keycode, mods, true)
        sendKeyEvent(keycode, mods, false)
    }

    /** Send a key combo (virtual key + modifier bitmask). */
    fun sendKeyCombo(keycode: Int, modifiers: Int) {
        sendVirtualKey(keycode, modifiers)
    }

    /** Type a string as Unicode character events. Empty string sends Return. */
    fun typeString(text: String) {
        if (text.isEmpty()) {
            sendVirtualKey(KEYCODE_RETURN)
            return
        }
        for (char in text) {
            when (char) {
                '\n', '\r' -> sendVirtualKey(KEYCODE_RETURN)
                '\t' -> sendVirtualKey(KEYCODE_TAB)
                else -> {
                    val code = char.code
                    sendKeyEvent(code, 0, true)
                    sendKeyEvent(code, 0, false)
                }
            }
        }
    }

    private fun sendInputEvent(event: com.peariscope.proto.PeariscopeProto.InputEvent) {
        if (streamId == 0) return
        try {
            networkManager.sendInputData(event.toByteArray(), streamId)
        } catch (_: Exception) {}
    }

    companion object {
        private const val TAP_TIMEOUT_MS = 200L
        private const val TAP_SLOP = 10f // pixels — smaller dead zone for faster drag start
        private const val TRACKPAD_SENSITIVITY = 1.5f // match iOS sensitivity

        /** Marker flag: tells host this keycode is a raw CGKeyCode, not Unicode */
        const val CGKEYCODE_FLAG = 0x80000000.toInt()

        // Modifier bitmask values
        const val MOD_SHIFT = 1
        const val MOD_CTRL = 2
        const val MOD_ALT = 4
        const val MOD_META = 8  // Cmd on macOS

        // macOS CGKeyCodes
        const val KEYCODE_RETURN = 36
        const val KEYCODE_TAB = 48
        const val KEYCODE_SPACE = 49
        const val KEYCODE_DELETE = 51  // Backspace
        const val KEYCODE_ESC = 53
        const val KEYCODE_FWD_DELETE = 117

        const val KEYCODE_LEFT = 123
        const val KEYCODE_RIGHT = 124
        const val KEYCODE_DOWN = 125
        const val KEYCODE_UP = 126
        const val KEYCODE_HOME = 115
        const val KEYCODE_END = 119
        const val KEYCODE_PGUP = 116
        const val KEYCODE_PGDN = 121

        const val KEYCODE_F1 = 122
        const val KEYCODE_F2 = 120
        const val KEYCODE_F3 = 99
        const val KEYCODE_F4 = 118
        const val KEYCODE_F5 = 96
        const val KEYCODE_F6 = 97
        const val KEYCODE_F7 = 98
        const val KEYCODE_F8 = 100
        const val KEYCODE_F9 = 101
        const val KEYCODE_F10 = 109
        const val KEYCODE_F11 = 103
        const val KEYCODE_F12 = 111

        // Common letter CGKeyCodes for shortcuts
        const val KEYCODE_A = 0
        const val KEYCODE_S = 1
        const val KEYCODE_D = 2
        const val KEYCODE_F = 3
        const val KEYCODE_G = 5
        const val KEYCODE_Z = 6
        const val KEYCODE_X = 7
        const val KEYCODE_C = 8
        const val KEYCODE_V = 9
        const val KEYCODE_B = 11
        const val KEYCODE_Q = 12
        const val KEYCODE_W = 13
        const val KEYCODE_E = 14
        const val KEYCODE_R = 15
        const val KEYCODE_T = 17
        const val KEYCODE_N = 45

        /** Map lowercase char to macOS CGKeyCode for combo shortcuts */
        val charToCGKeyCode = mapOf(
            'a' to 0, 's' to 1, 'd' to 2, 'f' to 3, 'h' to 4, 'g' to 5, 'z' to 6, 'x' to 7,
            'c' to 8, 'v' to 9, 'b' to 11, 'q' to 12, 'w' to 13, 'e' to 14, 'r' to 15,
            'y' to 16, 't' to 17, '1' to 18, '2' to 19, '3' to 20, '4' to 21, '6' to 22,
            '5' to 23, '=' to 24, '9' to 25, '7' to 26, '-' to 27, '8' to 28, '0' to 29,
            ']' to 30, 'o' to 31, 'u' to 32, '[' to 33, 'i' to 34, 'p' to 35, 'l' to 37,
            'j' to 38, '\'' to 39, 'k' to 40, ';' to 41, '\\' to 42, ',' to 43, '/' to 44,
            'n' to 45, 'm' to 46, '.' to 47, ' ' to 49, '`' to 50,
        )
    }
}
