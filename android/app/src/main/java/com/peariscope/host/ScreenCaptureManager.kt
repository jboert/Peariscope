package com.peariscope.host

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface

/**
 * Manages screen capture via MediaProjection API.
 * Provides a Surface that receives screen frames for encoding.
 */
class ScreenCaptureManager(private val context: Context) {

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null

    var screenWidth = 1920
        private set
    var screenHeight = 1080
        private set
    var screenDpi = 320
        private set

    val isCapturing: Boolean get() = virtualDisplay != null

    /**
     * Initialize with the MediaProjection result from the system permission dialog.
     * Call this from onActivityResult after requesting screen capture permission.
     */
    fun initialize(resultCode: Int, data: Intent) {
        val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = mgr.getMediaProjection(resultCode, data)

        // Get real screen metrics
        val dm = context.resources.displayMetrics
        screenWidth = dm.widthPixels
        screenHeight = dm.heightPixels
        screenDpi = dm.densityDpi
        Log.d(TAG, "MediaProjection initialized: ${screenWidth}x${screenHeight} @ ${screenDpi}dpi")
    }

    /**
     * Start capturing the screen to the given Surface (from MediaCodec encoder).
     * Frames are rendered directly to the Surface — no pixel buffer copies.
     */
    fun startCapture(surface: Surface, width: Int = screenWidth, height: Int = screenHeight) {
        val projection = mediaProjection ?: throw IllegalStateException("MediaProjection not initialized")

        virtualDisplay = projection.createVirtualDisplay(
            "PeariscopeCapture",
            width,
            height,
            screenDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            null
        )
        Log.d(TAG, "VirtualDisplay started: ${width}x${height}")
    }

    fun stopCapture() {
        virtualDisplay?.release()
        virtualDisplay = null
        Log.d(TAG, "VirtualDisplay stopped")
    }

    fun release() {
        stopCapture()
        mediaProjection?.stop()
        mediaProjection = null
        Log.d(TAG, "MediaProjection released")
    }

    companion object {
        private const val TAG = "ScreenCapture"

        /**
         * Create the intent to request screen capture permission.
         * Launch this with startActivityForResult.
         */
        fun createPermissionIntent(context: Context): Intent {
            val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            return mgr.createScreenCaptureIntent()
        }
    }
}
