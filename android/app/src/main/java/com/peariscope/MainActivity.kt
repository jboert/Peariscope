package com.peariscope

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.peariscope.host.HostSession
import com.peariscope.network.NetworkManager
import com.peariscope.ui.ConnectScreen
import com.peariscope.ui.ConnectingScreen
import com.peariscope.ui.HostScreen
import com.peariscope.ui.SettingsScreen
import com.peariscope.ui.ViewerScreen
import com.peariscope.ui.theme.PeariscopeTheme

class MainActivity : ComponentActivity() {
    private lateinit var networkManager: NetworkManager
    private lateinit var hostSession: HostSession

    // Shared state for PiP: Activity needs to know if viewer is active
    var isInViewerMode = mutableStateOf(false)
    var isInPipMode = mutableStateOf(false)
    private var videoWidth = 0
    private var videoHeight = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        networkManager = NetworkManager(applicationContext)
        networkManager.startNetworkMonitor()
        hostSession = HostSession(applicationContext, networkManager)

        // Auto-host on launch if enabled in settings
        val prefs = getSharedPreferences("peariscope", MODE_PRIVATE)
        val shouldAutoHost = prefs.getBoolean("autoHost", false)

        setContent {
            // Trigger auto-host once on first composition
            LaunchedEffect(Unit) {
                if (shouldAutoHost && !hostSession.isActive) {
                    // Need MediaProjection permission — can't auto-host without it.
                    // Auto-host only works if the user has previously granted capture permission
                    // and the foreground service is still running.
                    if (com.peariscope.host.MediaProjectionService.instance != null) {
                        hostSession.start()
                    }
                }
            }
            PeariscopeTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = Color.Black
                ) {
                    var isInHostMode by remember { mutableStateOf(false) }
                    var showSettings by remember { mutableStateOf(false) }
                    var isConnecting by remember { mutableStateOf(false) }

                    // Track connection state changes
                    DisposableEffect(networkManager) {
                        val prev = networkManager.onConnectionStateChanged
                        networkManager.onConnectionStateChanged = {
                            isConnecting = networkManager.isConnecting
                            if (networkManager.isConnected && !isInViewerMode.value) {
                                isInViewerMode.value = true
                                isConnecting = false
                            }
                            prev?.invoke()
                        }
                        onDispose {
                            networkManager.onConnectionStateChanged = prev
                        }
                    }

                    when {
                        showSettings -> {
                            SettingsScreen(
                                hostSession = hostSession,
                                onBack = { showSettings = false }
                            )
                        }
                        isInHostMode -> {
                            HostScreen(
                                hostSession = hostSession,
                                onStop = { isInHostMode = false }
                            )
                        }
                        isInViewerMode.value -> {
                            ViewerScreen(
                                networkManager = networkManager,
                                isInPipMode = isInPipMode.value,
                                onVideoSizeChanged = { w, h ->
                                    videoWidth = w
                                    videoHeight = h
                                },
                                onDisconnect = {
                                    networkManager.disconnectAll()
                                    isInViewerMode.value = false
                                }
                            )
                        }
                        isConnecting -> {
                            ConnectingScreen(
                                networkManager = networkManager,
                                onCancel = {
                                    networkManager.disconnectAll()
                                    isConnecting = false
                                }
                            )
                        }
                        else -> {
                            ConnectScreen(
                                networkManager = networkManager,
                                onConnected = { isInViewerMode.value = true },
                                onHost = { isInHostMode = true },
                                onSettings = { showSettings = true }
                            )
                        }
                    }
                }
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Enter PiP when user presses home while viewing
        if (isInViewerMode.value && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            enterPipMode()
        }
    }

    private fun enterPipMode() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val aspect = if (videoWidth > 0 && videoHeight > 0) {
            Rational(videoWidth, videoHeight)
        } else {
            Rational(16, 9)
        }
        val params = PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
            .build()
        enterPictureInPictureMode(params)
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode.value = isInPictureInPictureMode
    }

    override fun onPause() {
        super.onPause()
        // Don't suspend networking in PiP mode or when hosting
        if (isInPipMode.value || hostSession.isActive) return

        networkManager.suspendNetworking()
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            networkManager.bridge.suspend()
        }, 100)
    }

    override fun onResume() {
        super.onResume()
        networkManager.bridge.resume()
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            networkManager.resumeNetworking()
        }, 100)
    }

    override fun onDestroy() {
        super.onDestroy()
        hostSession.release()
        networkManager.shutdown()
    }
}
