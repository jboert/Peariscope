package com.peariscope.input

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * AccessibilityService that injects touch/click events into the system.
 * User must manually enable this in Settings > Accessibility > Peariscope.
 *
 * Receives commands from InputInjector via the static instance reference.
 */
class InputInjectorService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "InputInjectorService connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used — we only inject, not observe
    }

    override fun onInterrupt() {
        Log.d(TAG, "InputInjectorService interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        Log.d(TAG, "InputInjectorService destroyed")
    }

    /**
     * Inject a tap at normalized coordinates (0.0-1.0).
     */
    fun injectTap(normalizedX: Float, normalizedY: Float) {
        val metrics = getScreenMetrics()
        val x = normalizedX * metrics.widthPixels
        val y = normalizedY * metrics.heightPixels

        val path = Path()
        path.moveTo(x, y)

        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            .build()

        dispatchGesture(gesture, null, null)
    }

    /**
     * Inject a long press at normalized coordinates.
     */
    fun injectLongPress(normalizedX: Float, normalizedY: Float) {
        val metrics = getScreenMetrics()
        val x = normalizedX * metrics.widthPixels
        val y = normalizedY * metrics.heightPixels

        val path = Path()
        path.moveTo(x, y)

        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 600))
            .build()

        dispatchGesture(gesture, null, null)
    }

    /**
     * Inject a swipe/drag gesture.
     */
    fun injectSwipe(
        fromX: Float, fromY: Float,
        toX: Float, toY: Float,
        durationMs: Long = 300
    ) {
        val metrics = getScreenMetrics()
        val path = Path()
        path.moveTo(fromX * metrics.widthPixels, fromY * metrics.heightPixels)
        path.lineTo(toX * metrics.widthPixels, toY * metrics.heightPixels)

        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()

        dispatchGesture(gesture, null, null)
    }

    private fun getScreenMetrics(): DisplayMetrics {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        return metrics
    }

    companion object {
        private const val TAG = "InputInjectorSvc"

        /** Static instance — set when service is connected, null when not running. */
        @Volatile
        var instance: InputInjectorService? = null
            private set

        val isRunning: Boolean get() = instance != null
    }
}
