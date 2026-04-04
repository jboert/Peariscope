package com.peariscope.host

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import android.view.WindowManager

/**
 * Foreground service that owns the MediaProjection and capture pipeline.
 * Runs independently of the Activity lifecycle — screen capture continues
 * when the app is backgrounded. This is essential for Android hosting:
 * the user needs to interact with OTHER apps while sharing their screen.
 *
 * The Activity passes the MediaProjection result via Intent extras.
 * The service creates the projection, encoder, and VirtualDisplay.
 */
class MediaProjectionService : Service() {

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: ScreenEncoder? = null
    private val mainHandler = Handler(Looper.getMainLooper())


    var screenWidth = 1080
        private set
    var screenHeight = 1920
        private set

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Peariscope")
            .setContentText("Sharing screen")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        instance = this
        Log.d(TAG, "MediaProjection foreground service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val resultData = intent?.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)

        if (resultCode != 0 && resultData != null && mediaProjection == null) {
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjection = mgr.getMediaProjection(resultCode, resultData)

            // Get screen dimensions
            val wm = getSystemService(WINDOW_SERVICE) as WindowManager
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(dm)
            screenWidth = dm.widthPixels
            screenHeight = dm.heightPixels
            Log.d(TAG, "MediaProjection initialized: ${screenWidth}x${screenHeight}")
        }

        return START_NOT_STICKY
    }

    /**
     * Start the capture pipeline — called by HostSession when a viewer connects.
     * Returns the encoder for frame callbacks, or null if projection not ready.
     */
    fun startCapture(onEncodedData: (ByteArray, Boolean) -> Unit): ScreenEncoder? {
        val projection = mediaProjection ?: return null
        if (encoder != null) return encoder // already running

        val prefs = getSharedPreferences("peariscope", Context.MODE_PRIVATE)
        val bitrate = prefs.getInt("bitrate", 12_000_000)
        // Cap at 30fps for hosting — encoding at 60fps floods the IPC/worklet
        // and causes connection drops or requires frame dropping which creates artifacts.
        // At 30fps every frame is sent, no drops, no artifacts.
        val fps = minOf(prefs.getInt("fps", 60), 30)
        val enc = ScreenEncoder(screenWidth, screenHeight, fps = fps, bitrate = bitrate)
        val surface = enc.configure()
        enc.onEncodedData = onEncodedData
        enc.start()

        val dm = resources.displayMetrics
        virtualDisplay = projection.createVirtualDisplay(
            "PeariscopeCapture",
            screenWidth,
            screenHeight,
            dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            null
        )

        encoder = enc
        Log.d(TAG, "Capture pipeline started in service: ${screenWidth}x${screenHeight}")

        // Request initial keyframes so viewers get video quickly
        mainHandler.postDelayed({ encoder?.requestKeyframe() }, 200)
        mainHandler.postDelayed({ encoder?.requestKeyframe() }, 1000)

        return enc
    }

    fun stopCapture() {
        virtualDisplay?.release()
        virtualDisplay = null
        encoder?.stop()
        encoder = null
        Log.d(TAG, "Capture pipeline stopped in service")
    }

    fun requestKeyframe() {
        encoder?.requestKeyframe()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        stopCapture()
        mediaProjection?.stop()
        mediaProjection = null
        instance = null
        Log.d(TAG, "MediaProjection foreground service stopped")
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Screen Sharing",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Active while sharing your screen"
        }
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "MediaProjectionSvc"
        private const val CHANNEL_ID = "peariscope_projection"
        private const val NOTIFICATION_ID = 1001
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        @Volatile
        var instance: MediaProjectionService? = null
            private set
    }
}
