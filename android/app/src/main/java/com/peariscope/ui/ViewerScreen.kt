package com.peariscope.ui

import android.annotation.SuppressLint
import android.graphics.Canvas
import android.graphics.Paint
import android.util.Log
import android.graphics.SurfaceTexture
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.os.PowerManager
import com.peariscope.audio.AudioPlayer
import com.peariscope.input.InputSender
import com.peariscope.network.NetworkManager
import androidx.compose.ui.platform.LocalContext
import com.peariscope.clipboard.ClipboardSharing
import com.peariscope.ui.theme.PearGreen
import com.peariscope.video.VideoDecoder

@Composable
fun ViewerScreen(
    networkManager: NetworkManager,
    isInPipMode: Boolean = false,
    onVideoSizeChanged: ((Int, Int) -> Unit)? = null,
    onDisconnect: () -> Unit
) {
    val context = LocalContext.current
    val decoder = remember { VideoDecoder() }
    val audioPlayer = remember { AudioPlayer() }
    val inputSender = remember { InputSender(networkManager) }
    val clipboardSharing = remember { ClipboardSharing(context) }

    var hasReceivedFirstFrame by remember { mutableStateOf(false) }
    var fps by remember { mutableIntStateOf(0) }
    var showControls by remember { mutableStateOf(true) }
    var isTrackpadMode by remember { mutableStateOf(true) }
    var pendingPin by remember { mutableStateOf<String?>(null) }
    var pinEntryText by remember { mutableStateOf("") }
    var videoWidth by remember { mutableIntStateOf(0) }
    var videoHeight by remember { mutableIntStateOf(0) }
    var isReconnecting by remember { mutableStateOf(false) }
    var connectionLost by remember { mutableStateOf(false) }
    var showKeyboard by remember { mutableStateOf(false) }
    var showShortcuts by remember { mutableStateOf(false) }
    var inputText by remember { mutableStateOf("") }
    var activeModifiers by remember { mutableIntStateOf(0) }

    // Bandwidth tracking
    var bytesReceived by remember { mutableLongStateOf(0L) }
    var bandwidthBps by remember { mutableLongStateOf(0L) }

    // Cursor position from host
    var remoteCursorX by remember { mutableFloatStateOf(0.5f) }
    var remoteCursorY by remember { mutableFloatStateOf(0.5f) }

    // Thermal throttling
    var thermalStatus by remember { mutableIntStateOf(PowerManager.THERMAL_STATUS_NONE) }

    // Display switching
    var availableDisplays by remember { mutableStateOf<List<com.peariscope.proto.PeariscopeProto.DisplayInfo>>(emptyList()) }
    var activeDisplayId by remember { mutableIntStateOf(0) }

    // Memory pressure
    var workletSuspendedForMemory by remember { mutableStateOf(false) }

    var frameCount by remember { mutableIntStateOf(0) }
    var lastFpsTime by remember { mutableLongStateOf(System.currentTimeMillis()) }

    DisposableEffect(networkManager) {
        fun requestIdr(streamId: Int) {
            try {
                val idr = com.peariscope.proto.PeariscopeProto.RequestIdr.newBuilder().build()
                val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                    .setRequestIdr(idr).build()
                networkManager.sendControlData(control.toByteArray(), streamId)
            } catch (_: Exception) {}
        }

        fun sendQualityReport(streamId: Int) {
            try {
                val report = com.peariscope.proto.PeariscopeProto.QualityReport.newBuilder()
                    .setFps(fps)
                    .setReceivedKbps((bandwidthBps * 8 / 1000).toInt())
                val dm = android.content.res.Resources.getSystem().displayMetrics
                report.screenWidth = dm.widthPixels
                report.screenHeight = dm.heightPixels
                // Thermal throttling: request reduced bitrate/fps when device is hot
                when (thermalStatus) {
                    PowerManager.THERMAL_STATUS_SEVERE, PowerManager.THERMAL_STATUS_EMERGENCY -> {
                        report.bitrateKbps = 2000  // 2Mbps max
                        report.fps = 15
                    }
                    PowerManager.THERMAL_STATUS_MODERATE -> {
                        report.bitrateKbps = 4000  // 4Mbps max
                        report.fps = 30
                    }
                    // NONE, LIGHT — no restriction (bitrateKbps=0 means unrestricted)
                }
                val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                    .setQualityReport(report).build()
                networkManager.sendControlData(control.toByteArray(), streamId)
            } catch (_: Exception) {}
        }

        val existingPeer = networkManager.connectedPeers.firstOrNull()
        if (existingPeer != null) {
            inputSender.setStreamId(existingPeer.streamId)
            requestIdr(existingPeer.streamId)
        }

        val prevPeerCallback = networkManager.onPeerConnected
        networkManager.onPeerConnected = { peer ->
            inputSender.setStreamId(peer.streamId)
            isReconnecting = false
            connectionLost = false
            requestIdr(peer.streamId)
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ requestIdr(peer.streamId) }, 500)
            prevPeerCallback?.invoke(peer)
        }

        // Auto-reconnect on disconnect — relies on onPeerConnected callback
        // (above) to clear isReconnecting when connection succeeds.
        networkManager.onPeerDisconnected = { _ ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (networkManager.connectedPeers.isEmpty() && !isReconnecting) {
                    val code = networkManager.lastConnectionCode
                    if (code != null) {
                        isReconnecting = true
                        Log.d("ViewerScreen", "Connection lost, starting auto-reconnect")
                        fun attemptReconnect(attempt: Int) {
                            if (attempt > 5 || !isReconnecting) {
                                if (isReconnecting) {
                                    isReconnecting = false
                                    connectionLost = true
                                }
                                return
                            }
                            val delayMs = (attempt * 2000).toLong()
                            Log.d("ViewerScreen", "Reconnect attempt $attempt/5 (delay ${delayMs}ms)")
                            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                if (!isReconnecting) return@postDelayed
                                try {
                                    networkManager.connect(code)
                                } catch (_: Exception) {}
                                // Wait for the worklet's full connection cycle (up to 35s)
                                // before trying the next attempt. onPeerConnected will
                                // clear isReconnecting if the connection succeeds.
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    if (networkManager.connectedPeers.isEmpty() && isReconnecting) {
                                        attemptReconnect(attempt + 1)
                                    }
                                }, 35000)
                            }, delayMs)
                        }
                        attemptReconnect(1)
                    }
                }
            }
        }

        networkManager.onVideoData = { data ->
            decoder.decode(data)
            frameCount++
            bytesReceived += data.size
            val now = System.currentTimeMillis()
            if (now - lastFpsTime >= 1000) {
                fps = frameCount
                bandwidthBps = bytesReceived
                frameCount = 0
                bytesReceived = 0
                lastFpsTime = now
            }
        }

        networkManager.onAudioData = { data ->
            audioPlayer.decodeAndPlay(data)
        }

        networkManager.setControlDataCallback { data ->
            try {
                val control = com.peariscope.proto.PeariscopeProto.ControlMessage.parseFrom(data)
                when {
                    control.hasPeerChallenge() -> pendingPin = control.peerChallenge.pin
                    control.hasPeerChallengeResponse() -> {
                        if (control.peerChallengeResponse.accepted) {
                            pendingPin = null; pinEntryText = ""
                        }
                    }
                    control.hasCursorPosition() -> {
                        remoteCursorX = control.cursorPosition.x
                        remoteCursorY = control.cursorPosition.y
                    }
                    control.hasDisplayList() -> {
                        availableDisplays = control.displayList.displaysList
                        val active = availableDisplays.firstOrNull { it.isActive }
                        if (active != null) activeDisplayId = active.displayId
                    }
                    control.hasClipboard() -> {
                        val cb = control.clipboard
                        if (cb.text.isNotEmpty()) {
                            clipboardSharing.applyRemoteClipboard(cb.text)
                        }
                        if (!cb.imagePng.isEmpty) {
                            clipboardSharing.applyRemoteImage(cb.imagePng.toByteArray())
                        }
                    }
                }
            } catch (_: Exception) {}
        }

        // Clipboard sharing — send local clipboard changes to host
        clipboardSharing.onClipboardChanged = cb@{ text ->
            val peer = networkManager.connectedPeers.firstOrNull() ?: return@cb
            try {
                val cbData = com.peariscope.proto.PeariscopeProto.ClipboardData.newBuilder()
                    .setText(text).build()
                val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                    .setClipboard(cbData).build()
                networkManager.sendControlData(control.toByteArray(), peer.streamId)
            } catch (_: Exception) {}
        }
        clipboardSharing.onImageClipboardChanged = cb@{ pngData ->
            val peer = networkManager.connectedPeers.firstOrNull() ?: return@cb
            try {
                val cbData = com.peariscope.proto.PeariscopeProto.ClipboardData.newBuilder()
                    .setImagePng(com.google.protobuf.ByteString.copyFrom(pngData)).build()
                val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                    .setClipboard(cbData).build()
                networkManager.sendControlData(control.toByteArray(), peer.streamId)
            } catch (_: Exception) {}
        }
        clipboardSharing.startMonitoring()

        decoder.onFirstFrame = { hasReceivedFirstFrame = true }
        decoder.onFormatChanged = { w, h ->
            videoWidth = w; videoHeight = h
            onVideoSizeChanged?.invoke(w, h)
        }
        decoder.onRequestIdr = {
            val peer = networkManager.connectedPeers.firstOrNull()
            if (peer != null) requestIdr(peer.streamId)
        }

        try { audioPlayer.start() } catch (_: Exception) {}

        // Quality report timer — send every 2 seconds
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        val qualityRunnable = object : Runnable {
            override fun run() {
                val peer = networkManager.connectedPeers.firstOrNull()
                if (peer != null) sendQualityReport(peer.streamId)
                handler.postDelayed(this, 2000)
            }
        }
        handler.postDelayed(qualityRunnable, 2000)

        // IDR retry timer
        val idrRunnable = object : Runnable {
            var retries = 0
            override fun run() {
                if (!hasReceivedFirstFrame && retries < 10) {
                    val peer = networkManager.connectedPeers.firstOrNull()
                    if (peer != null) requestIdr(peer.streamId)
                    retries++
                    handler.postDelayed(this, 2000)
                }
            }
        }
        handler.postDelayed(idrRunnable, 1000)

        // Thermal monitoring — register listener for thermal status changes
        val powerManager = context.getSystemService(android.content.Context.POWER_SERVICE) as? PowerManager
        val thermalListener = PowerManager.OnThermalStatusChangedListener { status ->
            thermalStatus = status
            android.util.Log.d("Peariscope", "THERMAL: status=$status (${
                when (status) {
                    PowerManager.THERMAL_STATUS_NONE -> "none"
                    PowerManager.THERMAL_STATUS_LIGHT -> "light"
                    PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                    PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                    PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                    PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                    else -> "unknown"
                }
            })")
            // Send immediate quality report with thermal hint
            val peer = networkManager.connectedPeers.firstOrNull()
            if (peer != null) sendQualityReport(peer.streamId)
        }
        thermalStatus = powerManager?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
        powerManager?.addThermalStatusListener(thermalListener)

        // Memory pressure handling — terminate worklet when memory is critically low,
        // stay in viewer and auto-reconnect (matches iOS behavior).
        fun getAvailableMemoryMB(): Long {
            val activityManager = context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return -1
            val memInfo = ActivityManager.MemoryInfo()
            activityManager.getMemoryInfo(memInfo)
            return memInfo.availMem / (1024 * 1024)
        }

        fun handleMemoryPressure() {
            if (workletSuspendedForMemory) return
            workletSuspendedForMemory = true
            val availMB = getAvailableMemoryMB()
            android.util.Log.w("Peariscope", "MEMORY PRESSURE: ${availMB}MB — terminating worklet, will reconnect")

            // Save connection code before disconnectAll clears it
            val savedCode = networkManager.lastConnectionCode

            // Stop data flow
            networkManager.onVideoData = null
            networkManager.onAudioData = null
            decoder.stop()
            audioPlayer.stop()

            // Kill the worklet to free V8/libuv memory
            networkManager.disconnectAll()
            networkManager.shutdown()

            // Stay in viewer, show reconnecting banner
            isReconnecting = true

            // Wait 3s for memory to recover, then reconnect
            handler.postDelayed({
                workletSuspendedForMemory = false
                if (savedCode != null && isReconnecting) {
                    val reconnectAvailMB = getAvailableMemoryMB()
                    android.util.Log.d("Peariscope", "MEMORY RECONNECT: mem=${reconnectAvailMB}MB, reconnecting...")

                    // Re-setup video/audio callbacks
                    networkManager.onVideoData = { data ->
                        decoder.decode(data)
                        frameCount++
                        bytesReceived += data.size
                        val now = System.currentTimeMillis()
                        if (now - lastFpsTime >= 1000) {
                            fps = frameCount
                            bandwidthBps = bytesReceived
                            frameCount = 0
                            bytesReceived = 0
                            lastFpsTime = now
                        }
                    }
                    networkManager.onAudioData = { data ->
                        audioPlayer.decodeAndPlay(data)
                    }
                    try { audioPlayer.start() } catch (_: Exception) {}

                    networkManager.connect(savedCode)
                } else {
                    isReconnecting = false
                    connectionLost = true
                }
            }, 3000)
        }

        val memoryCallbacks = object : ComponentCallbacks2 {
            override fun onConfigurationChanged(newConfig: Configuration) {}
            override fun onLowMemory() {
                if (!workletSuspendedForMemory) {
                    android.util.Log.w("Peariscope", "onLowMemory — triggering memory pressure handler")
                    handler.post { handleMemoryPressure() }
                }
            }
            override fun onTrimMemory(level: Int) {
                if (workletSuspendedForMemory) return
                // TRIM_MEMORY_RUNNING_CRITICAL (15) = process is running but system is critically low
                // TRIM_MEMORY_COMPLETE (80) = process is near background LRU kill
                if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
                    val availMB = getAvailableMemoryMB()
                    android.util.Log.w("Peariscope", "onTrimMemory level=$level, availMem=${availMB}MB")
                    if (availMB in 1..199) {
                        handler.post { handleMemoryPressure() }
                    }
                }
            }
        }
        context.applicationContext.registerComponentCallbacks(memoryCallbacks)

        // Periodic memory check (heartbeat) — catches gradual memory drain
        // that doesn't trigger system callbacks fast enough
        val memoryCheckRunnable = object : Runnable {
            override fun run() {
                if (!workletSuspendedForMemory) {
                    val availMB = getAvailableMemoryMB()
                    if (availMB in 1..149) {
                        android.util.Log.w("Peariscope", "MEMORY HEARTBEAT: ${availMB}MB — triggering pressure handler")
                        handleMemoryPressure()
                    }
                }
                handler.postDelayed(this, 1000)
            }
        }
        handler.postDelayed(memoryCheckRunnable, 1000)

        onDispose {
            clipboardSharing.stopMonitoring()
            context.applicationContext.unregisterComponentCallbacks(memoryCallbacks)
            powerManager?.removeThermalStatusListener(thermalListener)
            networkManager.onVideoData = null
            networkManager.onAudioData = null
            networkManager.setControlDataCallback(null)
            networkManager.onPeerConnected = null
            networkManager.onPeerDisconnected = null
            handler.removeCallbacksAndMessages(null)
            decoder.stop()
            audioPlayer.stop()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        // Zoomable video + cursor overlay
        AndroidView(
            factory = { context ->
                ZoomableTextureContainer(context, decoder, inputSender, isTrackpadMode,
                    onToggleControls = { showControls = !showControls })
            },
            update = { container ->
                container.isTrackpadMode = isTrackpadMode
                if (videoWidth > 0 && videoHeight > 0) {
                    container.setVideoSize(videoWidth, videoHeight)
                }
                container.setCursorPosition(remoteCursorX, remoteCursorY)
            },
            modifier = Modifier.fillMaxSize()
        )

        // Loading overlay (hidden in PiP)
        if (!isInPipMode && !hasReceivedFirstFrame && pendingPin == null) {
            Box(
                modifier = Modifier.fillMaxSize().background(Color.Black),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = PearGreen, modifier = Modifier.size(32.dp), strokeWidth = 3.dp)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("Waiting for video...", color = Color.Gray, fontSize = 14.sp)
                }
            }
        }

        // Reconnecting banner (hidden in PiP)
        if (!isInPipMode && isReconnecting) {
            Box(
                modifier = Modifier.fillMaxWidth().padding(top = 60.dp),
                contentAlignment = Alignment.TopCenter
            ) {
                Surface(shape = RoundedCornerShape(8.dp), color = Color(0xCC000000)) {
                    Row(
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(color = PearGreen, modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                        Text("Reconnecting...", color = Color.White, fontSize = 12.sp)
                    }
                }
            }
        }

        // Connection lost banner (hidden in PiP)
        if (!isInPipMode && connectionLost) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                Surface(shape = RoundedCornerShape(16.dp), color = Color(0xCC000000)) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Text("Connection Lost", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                        TextButton(onClick = onDisconnect) {
                            Text("Disconnect", color = PearGreen)
                        }
                    }
                }
            }
        }

        // Top bar with stats (hidden in PiP)
        if (!isInPipMode && (showControls || !hasReceivedFirstFrame)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Stats: FPS + bandwidth
                Surface(shape = RoundedCornerShape(8.dp), color = Color.Black.copy(alpha = 0.6f)) {
                    Row(
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // FPS dot
                        Box(modifier = Modifier.size(5.dp).background(
                            if (fps > 30) PearGreen else Color.Yellow, CircleShape))
                        Text(
                            "$fps",
                            color = Color.White,
                            fontSize = 11.sp, fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace
                        )
                        // Bandwidth
                        if (bandwidthBps > 0) {
                            val bwText = if (bandwidthBps >= 1_000_000) {
                                String.format("%.1fMB/s", bandwidthBps / 1_000_000.0)
                            } else {
                                "${bandwidthBps / 1000}KB/s"
                            }
                            Text(bwText, color = Color.Gray, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                        }
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    // Display switcher
                    if (availableDisplays.size > 1) {
                        var displayMenuExpanded by remember { mutableStateOf(false) }
                        Box {
                            Surface(
                                onClick = { displayMenuExpanded = true },
                                shape = RoundedCornerShape(8.dp),
                                color = Color.Black.copy(alpha = 0.6f)
                            ) {
                                Icon(
                                    painter = androidx.compose.ui.res.painterResource(android.R.drawable.ic_menu_slideshow),
                                    contentDescription = "Switch Display",
                                    tint = Color.White,
                                    modifier = Modifier.padding(8.dp).size(18.dp)
                                )
                            }
                            DropdownMenu(
                                expanded = displayMenuExpanded,
                                onDismissRequest = { displayMenuExpanded = false }
                            ) {
                                availableDisplays.forEach { display ->
                                    DropdownMenuItem(
                                        text = {
                                            Row(
                                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Text(
                                                    if (display.name.isNotEmpty()) display.name
                                                    else "${display.width}x${display.height}"
                                                )
                                                if (display.displayId == activeDisplayId) {
                                                    Text("✓", fontWeight = FontWeight.Bold, color = PearGreen)
                                                }
                                            }
                                        },
                                        onClick = {
                                            displayMenuExpanded = false
                                            activeDisplayId = display.displayId
                                            switchDisplay(networkManager, display.displayId)
                                        }
                                    )
                                }
                            }
                        }
                    }

                    // Keyboard toggle
                    Surface(
                        onClick = { showKeyboard = !showKeyboard },
                        shape = RoundedCornerShape(8.dp),
                        color = if (showKeyboard) PearGreen.copy(alpha = 0.3f) else Color.Black.copy(alpha = 0.6f)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Keyboard,
                            contentDescription = "Keyboard",
                            tint = if (showKeyboard) PearGreen else Color.White,
                            modifier = Modifier.padding(8.dp).size(18.dp)
                        )
                    }

                    // Trackpad/Direct mode toggle
                    Surface(
                        onClick = { isTrackpadMode = !isTrackpadMode },
                        shape = RoundedCornerShape(8.dp),
                        color = Color.Black.copy(alpha = 0.6f)
                    ) {
                        Icon(
                            imageVector = if (isTrackpadMode) Icons.Default.TouchApp else Icons.Default.Mouse,
                            contentDescription = if (isTrackpadMode) "Trackpad" else "Direct",
                            tint = Color.White,
                            modifier = Modifier.padding(8.dp).size(18.dp)
                        )
                    }

                    // Disconnect
                    Surface(onClick = onDisconnect, shape = CircleShape, color = Color.Red.copy(alpha = 0.7f)) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Disconnect",
                            tint = Color.White,
                            modifier = Modifier.padding(6.dp).size(18.dp)
                        )
                    }
                }
            }
        }

        // Keyboard panel (hidden in PiP)
        if (!isInPipMode && showKeyboard) {
            KeyboardPanel(
                inputSender = inputSender,
                inputText = inputText,
                onInputTextChange = { inputText = it },
                activeModifiers = activeModifiers,
                onModifiersChange = { activeModifiers = it },
                showShortcuts = showShortcuts,
                onToggleShortcuts = { showShortcuts = !showShortcuts }
            )
        }

        // PIN dialog (hidden in PiP)
        if (!isInPipMode && pendingPin != null) {
            AlertDialog(
                onDismissRequest = {
                    sendPinResponse(networkManager, pendingPin, false)
                    pendingPin = null; pinEntryText = ""; onDisconnect()
                },
                title = { Text("PIN Verification") },
                text = {
                    Column {
                        Text("Enter the PIN shown on the host:")
                        Spacer(modifier = Modifier.height(12.dp))
                        OutlinedTextField(
                            value = pinEntryText,
                            onValueChange = { pinEntryText = it.filter { c -> c.isDigit() } },
                            placeholder = { Text("Enter PIN") },
                            singleLine = true,
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                                keyboardType = androidx.compose.ui.text.input.KeyboardType.NumberPassword
                            )
                        )
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        sendPinResponse(networkManager, pinEntryText, true)
                        // Don't clear pendingPin — wait for host's accepted response
                    }) { Text("Submit") }
                },
                dismissButton = {
                    TextButton(onClick = {
                        sendPinResponse(networkManager, pendingPin, false)
                        pendingPin = null; pinEntryText = ""; onDisconnect()
                    }) { Text("Cancel") }
                }
            )
        }
    }
}

private fun sendPinResponse(networkManager: NetworkManager, pin: String?, accepted: Boolean) {
    val peers = networkManager.connectedPeers
    if (peers.isEmpty() || pin == null) return
    try {
        val peer = peers.last()
        val response = com.peariscope.proto.PeariscopeProto.PeerChallengeResponse.newBuilder()
            .setPin(pin).setAccepted(accepted).build()
        val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
            .setPeerChallengeResponse(response).build()
        networkManager.sendControlData(control.toByteArray(), peer.streamId)
    } catch (_: Exception) {}
}

private fun switchDisplay(networkManager: NetworkManager, displayId: Int) {
    val peers = networkManager.connectedPeers
    if (peers.isEmpty()) return
    try {
        val switchMsg = com.peariscope.proto.PeariscopeProto.SwitchDisplay.newBuilder()
            .setDisplayId(displayId).build()
        val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
            .setSwitchDisplay(switchMsg).build()
        for (peer in peers) {
            networkManager.sendControlData(control.toByteArray(), peer.streamId)
        }
    } catch (_: Exception) {}
}

/**
 * Zoomable/pannable video container with cursor overlay.
 */
@SuppressLint("ClickableViewAccessibility")
private class ZoomableTextureContainer(
    context: android.content.Context,
    private val decoder: VideoDecoder,
    private val inputSender: InputSender,
    var isTrackpadMode: Boolean,
    private val onToggleControls: () -> Unit
) : FrameLayout(context) {

    private val textureView = TextureView(context)
    private val cursorView = CursorOverlay(context)
    private var surface: Surface? = null

    private var currentScale = 1f
    private var panX = 0f
    private var panY = 0f
    private var videoW = 0
    private var videoH = 0
    private var baseW = 0
    private var baseH = 0
    private var initialScale = 1f
    private var minScale = 1f
    private var maxScale = 5f
    private var isScaling = false
    private var singleFingerActive = false

    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var pointerCount = 0

    private var tapDownTime = 0L
    private var tapDownX = 0f
    private var tapDownY = 0f

    // Double-tap detection
    private var lastTapTime = 0L

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            isScaling = true
            singleFingerActive = false
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val newScale = (currentScale * detector.scaleFactor).coerceIn(minScale, maxScale)
            val fx = detector.focusX
            val fy = detector.focusY
            panX = fx - (fx - panX) * (newScale / currentScale)
            panY = fy - (fy - panY) * (newScale / currentScale)
            currentScale = newScale
            clampPan()
            applyTransform()
            return true
        }

        override fun onScaleEnd(detector: ScaleGestureDetector) {
            isScaling = false
            // Snap back to 1.0 if barely zoomed
            if (currentScale < minScale * 1.1f && currentScale > minScale) {
                currentScale = minScale
                panX = 0f; panY = 0f
                clampPan()
                applyTransform()
            }
        }
    })

    init {
        setBackgroundColor(android.graphics.Color.BLACK)

        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
                surface = Surface(st)
                decoder.configure(surface!!)
            }
            override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                decoder.stop()
                surface?.release()
                surface = null
                return true
            }
            override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
        }

        addView(textureView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER))
        addView(cursorView, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
    }

    fun setVideoSize(w: Int, h: Int) {
        if (w == videoW && h == videoH) return
        videoW = w
        videoH = h
        post { updateLayout() }
    }

    fun setCursorPosition(nx: Float, ny: Float) {
        if (baseW <= 0 || baseH <= 0) return

        // Auto-pan viewport to follow cursor when the video extends beyond the screen
        val scaledW = baseW * currentScale
        val scaledH = baseH * currentScale
        if (scaledW > width * 1.05f || scaledH > height * 1.05f) {
            val cx0 = width / 2f + panX
            val cy0 = height / 2f + panY
            val left0 = cx0 - baseW * currentScale / 2f
            val top0 = cy0 - baseH * currentScale / 2f
            val sx = left0 + nx * baseW * currentScale
            val sy = top0 + ny * baseH * currentScale

            val marginX = width * 0.15f
            val marginY = height * 0.15f
            var needsUpdate = false

            if (sx < marginX) {
                panX += marginX - sx; needsUpdate = true
            } else if (sx > width - marginX) {
                panX -= sx - (width - marginX); needsUpdate = true
            }
            if (sy < marginY) {
                panY += marginY - sy; needsUpdate = true
            } else if (sy > height - marginY) {
                panY -= sy - (height - marginY); needsUpdate = true
            }

            if (needsUpdate) {
                clampPan()
                applyTransform()
            }
        }

        // Convert normalized cursor to screen coords (using potentially updated pan)
        val cx = width / 2f + panX
        val cy = height / 2f + panY
        val left = cx - baseW * currentScale / 2f
        val top = cy - baseH * currentScale / 2f
        val screenX = left + nx * baseW * currentScale
        val screenY = top + ny * baseH * currentScale
        cursorView.setCursor(screenX, screenY)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (videoW > 0 && videoH > 0) updateLayout()
    }

    private fun updateLayout() {
        val cw = width
        val ch = height
        if (cw <= 0 || ch <= 0 || videoW <= 0 || videoH <= 0) return

        val videoAspect = videoW.toFloat() / videoH
        val containerAspect = cw.toFloat() / ch

        if (videoAspect > containerAspect) {
            baseW = cw
            baseH = (cw / videoAspect).toInt()
        } else {
            baseW = (ch * videoAspect).toInt()
            baseH = ch
        }

        val lp = textureView.layoutParams as LayoutParams
        lp.width = baseW
        lp.height = baseH
        lp.gravity = Gravity.CENTER
        textureView.layoutParams = lp

        val fitHeightScale = ch.toFloat() / baseH
        initialScale = fitHeightScale
        minScale = 1f
        maxScale = maxOf(fitHeightScale * 3f, 5f)

        currentScale = initialScale
        panX = 0f
        panY = 0f
        clampPan()
        applyTransform()
    }

    private fun clampPan() {
        val cw = width.toFloat()
        val ch = height.toFloat()
        val scaledW = baseW * currentScale
        val scaledH = baseH * currentScale

        if (scaledW <= cw) panX = 0f
        else panX = panX.coerceIn(-(scaledW - cw) / 2f, (scaledW - cw) / 2f)

        if (scaledH <= ch) panY = 0f
        else panY = panY.coerceIn(-(scaledH - ch) / 2f, (scaledH - ch) / 2f)
    }

    private fun applyTransform() {
        textureView.scaleX = currentScale
        textureView.scaleY = currentScale
        textureView.translationX = panX
        textureView.translationY = panY
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = true

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        pointerCount = event.pointerCount

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                singleFingerActive = true
                isScaling = false
                lastTouchX = event.x
                lastTouchY = event.y
                tapDownTime = System.currentTimeMillis()
                tapDownX = event.x
                tapDownY = event.y
                forwardToInput(event)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                singleFingerActive = false
                lastTouchX = avgX(event)
                lastTouchY = avgY(event)
            }

            MotionEvent.ACTION_MOVE -> {
                if (event.pointerCount >= 2) {
                    if (!isScaling) {
                        val ax = avgX(event)
                        val ay = avgY(event)
                        panX += ax - lastTouchX
                        panY += ay - lastTouchY
                        clampPan()
                        applyTransform()
                        lastTouchX = ax
                        lastTouchY = ay
                    } else {
                        lastTouchX = avgX(event)
                        lastTouchY = avgY(event)
                    }
                } else if (singleFingerActive) {
                    forwardToInput(event)
                }
            }

            MotionEvent.ACTION_UP -> {
                if (singleFingerActive) {
                    forwardToInput(event)
                    val elapsed = System.currentTimeMillis() - tapDownTime
                    val dx = Math.abs(event.x - tapDownX)
                    val dy = Math.abs(event.y - tapDownY)
                    if (elapsed < 250 && dx < 20 && dy < 20) {
                        // Double-tap: toggle zoom
                        val now = System.currentTimeMillis()
                        if (now - lastTapTime < 400) {
                            if (currentScale > minScale * 1.2f) {
                                // Zoom out to fit
                                currentScale = minScale
                                panX = 0f; panY = 0f
                            } else {
                                // Zoom to 1:1 centered on tap
                                val oneToOneScale = maxOf(
                                    videoW.toFloat() / baseW,
                                    videoH.toFloat() / baseH,
                                    initialScale * 2f
                                ).coerceAtMost(maxScale)
                                val fx = event.x
                                val fy = event.y
                                panX = fx - (fx - panX) * (oneToOneScale / currentScale)
                                panY = fy - (fy - panY) * (oneToOneScale / currentScale)
                                currentScale = oneToOneScale
                            }
                            clampPan()
                            applyTransform()
                            lastTapTime = 0
                        } else {
                            lastTapTime = now
                            // Single tap: toggle controls (delayed to distinguish from double-tap)
                            val tapTime = now
                            postDelayed({
                                if (lastTapTime == tapTime) onToggleControls()
                            }, 400)
                        }
                    }
                }
                singleFingerActive = false
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (event.pointerCount > 2) {
                    lastTouchX = avgX(event)
                    lastTouchY = avgY(event)
                }
            }
        }
        return true
    }

    private fun avgX(event: MotionEvent): Float {
        var sum = 0f
        for (i in 0 until event.pointerCount) sum += event.getX(i)
        return sum / event.pointerCount
    }

    private fun avgY(event: MotionEvent): Float {
        var sum = 0f
        for (i in 0 until event.pointerCount) sum += event.getY(i)
        return sum / event.pointerCount
    }

    private fun forwardToInput(event: MotionEvent) {
        if (baseW <= 0 || baseH <= 0) return
        val cx = width / 2f + panX
        val cy = height / 2f + panY
        val left = cx - baseW * currentScale / 2f
        val top = cy - baseH * currentScale / 2f
        val texX = (event.x - left) / (baseW * currentScale) * baseW
        val texY = (event.y - top) / (baseH * currentScale) * baseH
        val transformed = MotionEvent.obtain(event)
        transformed.setLocation(texX, texY)
        inputSender.handleMotionEvent(transformed, baseW, baseH, isTrackpadMode)
        transformed.recycle()
    }
}

@Composable
private fun BoxScope.KeyboardPanel(
    inputSender: InputSender,
    inputText: String,
    onInputTextChange: (String) -> Unit,
    activeModifiers: Int,
    onModifiersChange: (Int) -> Unit,
    showShortcuts: Boolean,
    onToggleShortcuts: () -> Unit
) {
    fun sendShortcut(keycode: Int, modifiers: Int = 0) {
        val combined = modifiers or activeModifiers
        inputSender.sendKeyCombo(keycode, combined)
        onModifiersChange(0)
    }

    fun sendInputText() {
        if (inputText.isEmpty()) {
            inputSender.sendVirtualKey(InputSender.KEYCODE_RETURN)
        } else {
            if (activeModifiers != 0) {
                for (char in inputText.lowercase()) {
                    val keycode = InputSender.charToCGKeyCode[char]
                    if (keycode != null) {
                        inputSender.sendKeyCombo(keycode, activeModifiers)
                    }
                }
                onModifiersChange(0)
            } else {
                inputSender.typeString(inputText)
            }
            onInputTextChange("")
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .align(Alignment.BottomCenter)
            .background(Color.Black.copy(alpha = 0.85f))
            .navigationBarsPadding()
    ) {
        // Shortcuts panel (expandable)
        if (showShortcuts) {
            Column(modifier = Modifier.padding(vertical = 8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    ShortcutButton("Copy") { sendShortcut(InputSender.KEYCODE_C, InputSender.MOD_META) }
                    ShortcutButton("Paste") { sendShortcut(InputSender.KEYCODE_V, InputSender.MOD_META) }
                    ShortcutButton("Cut") { sendShortcut(InputSender.KEYCODE_X, InputSender.MOD_META) }
                    ShortcutButton("Undo") { sendShortcut(InputSender.KEYCODE_Z, InputSender.MOD_META) }
                    ShortcutButton("Redo") { sendShortcut(InputSender.KEYCODE_Z, InputSender.MOD_META or InputSender.MOD_SHIFT) }
                    ShortcutButton("All") { sendShortcut(InputSender.KEYCODE_A, InputSender.MOD_META) }
                    ShortcutButton("Find") { sendShortcut(InputSender.KEYCODE_F, InputSender.MOD_META) }
                    ShortcutButton("Save") { sendShortcut(InputSender.KEYCODE_S, InputSender.MOD_META) }
                    ShortcutButton("Tab+") { sendShortcut(InputSender.KEYCODE_T, InputSender.MOD_META) }
                    ShortcutButton("Close") { sendShortcut(InputSender.KEYCODE_W, InputSender.MOD_META) }
                    ShortcutButton("Quit") { sendShortcut(InputSender.KEYCODE_Q, InputSender.MOD_META) }
                }
                Spacer(modifier = Modifier.height(6.dp))
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    NavButton("\u2190") { sendShortcut(InputSender.KEYCODE_LEFT) }
                    NavButton("\u2193") { sendShortcut(InputSender.KEYCODE_DOWN) }
                    NavButton("\u2191") { sendShortcut(InputSender.KEYCODE_UP) }
                    NavButton("\u2192") { sendShortcut(InputSender.KEYCODE_RIGHT) }
                    NavButton("Home") { sendShortcut(InputSender.KEYCODE_HOME) }
                    NavButton("End") { sendShortcut(InputSender.KEYCODE_END) }
                    NavButton("PgUp") { sendShortcut(InputSender.KEYCODE_PGUP) }
                    NavButton("PgDn") { sendShortcut(InputSender.KEYCODE_PGDN) }
                    NavButton("Del") { sendShortcut(InputSender.KEYCODE_FWD_DELETE) }
                    NavButton("Spc") { sendShortcut(InputSender.KEYCODE_SPACE) }
                }
                Spacer(modifier = Modifier.height(6.dp))
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    NavButton("F1") { sendShortcut(InputSender.KEYCODE_F1) }
                    NavButton("F2") { sendShortcut(InputSender.KEYCODE_F2) }
                    NavButton("F3") { sendShortcut(InputSender.KEYCODE_F3) }
                    NavButton("F4") { sendShortcut(InputSender.KEYCODE_F4) }
                    NavButton("F5") { sendShortcut(InputSender.KEYCODE_F5) }
                    NavButton("F6") { sendShortcut(InputSender.KEYCODE_F6) }
                    NavButton("F7") { sendShortcut(InputSender.KEYCODE_F7) }
                    NavButton("F8") { sendShortcut(InputSender.KEYCODE_F8) }
                    NavButton("F9") { sendShortcut(InputSender.KEYCODE_F9) }
                    NavButton("F10") { sendShortcut(InputSender.KEYCODE_F10) }
                    NavButton("F11") { sendShortcut(InputSender.KEYCODE_F11) }
                    NavButton("F12") { sendShortcut(InputSender.KEYCODE_F12) }
                }
            }
        }

        // Modifier keys + Esc/Tab
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ModifierPill("ctrl", InputSender.MOD_CTRL, activeModifiers, onModifiersChange)
            Spacer(modifier = Modifier.width(6.dp))
            ModifierPill("alt", InputSender.MOD_ALT, activeModifiers, onModifiersChange)
            Spacer(modifier = Modifier.width(6.dp))
            ModifierPill("shift", InputSender.MOD_SHIFT, activeModifiers, onModifiersChange)
            Spacer(modifier = Modifier.width(6.dp))
            ModifierPill("cmd", InputSender.MOD_META, activeModifiers, onModifiersChange)
            Spacer(modifier = Modifier.weight(1f))
            NavButton("Esc") { sendShortcut(InputSender.KEYCODE_ESC) }
            Spacer(modifier = Modifier.width(6.dp))
            NavButton("Tab") { sendShortcut(InputSender.KEYCODE_TAB) }
        }

        // Text input row
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(
                onClick = onToggleShortcuts,
                shape = RoundedCornerShape(8.dp),
                color = if (showShortcuts) PearGreen.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.1f)
            ) {
                Text(
                    "\u2318",
                    color = if (showShortcuts) PearGreen else Color.White.copy(alpha = 0.85f),
                    fontSize = 16.sp,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                )
            }
            Spacer(modifier = Modifier.width(8.dp))
            OutlinedTextField(
                value = inputText,
                onValueChange = onInputTextChange,
                placeholder = { Text("Type here...", color = Color.Gray, fontSize = 13.sp) },
                singleLine = true,
                modifier = Modifier.weight(1f).height(44.dp),
                textStyle = LocalTextStyle.current.copy(color = Color.White, fontSize = 13.sp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = PearGreen,
                    unfocusedBorderColor = Color.White.copy(alpha = 0.2f),
                    cursorColor = PearGreen
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { sendInputText() })
            )
            Spacer(modifier = Modifier.width(8.dp))
            Surface(
                onClick = { sendInputText() },
                shape = RoundedCornerShape(8.dp),
                color = PearGreen.copy(alpha = 0.2f)
            ) {
                Text(
                    "\u21B5",
                    color = PearGreen,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                )
            }
        }
        Spacer(modifier = Modifier.height(4.dp))
    }
}

@Composable
private fun ModifierPill(label: String, flag: Int, activeModifiers: Int, onModifiersChange: (Int) -> Unit) {
    val isActive = activeModifiers and flag != 0
    Surface(
        onClick = {
            onModifiersChange(if (isActive) activeModifiers and flag.inv() else activeModifiers or flag)
        },
        shape = RoundedCornerShape(6.dp),
        color = if (isActive) PearGreen else Color.White.copy(alpha = 0.12f)
    ) {
        Text(
            label,
            color = if (isActive) Color.Black else Color.White.copy(alpha = 0.85f),
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
        )
    }
}

@Composable
private fun ShortcutButton(label: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = Color.White.copy(alpha = 0.1f)
    ) {
        Text(
            label,
            color = Color.White.copy(alpha = 0.9f),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
        )
    }
}

@Composable
private fun NavButton(label: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = Color.White.copy(alpha = 0.1f)
    ) {
        Text(
            label,
            color = Color.White.copy(alpha = 0.9f),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp)
        )
    }
}

/**
 * Cursor arrow overlay using a pre-rendered bitmap and hardware-accelerated
 * translation. Matches iOS CursorView proportions. Choreographer drives
 * smooth position updates at display refresh rate.
 */
private class CursorOverlay(context: android.content.Context) : android.widget.ImageView(context),
    android.view.Choreographer.FrameCallback {

    @Volatile private var targetX = -1f
    @Volatile private var targetY = -1f
    private var isRunning = true

    init {
        val density = context.resources.displayMetrics.density
        val w = 18f * density
        val h = 22f * density
        val pad = 4f * density // shadow padding

        // Pre-render cursor to bitmap (done once)
        val bmpW = (w + pad * 2).toInt()
        val bmpH = (h + pad * 2).toInt()
        val bitmap = android.graphics.Bitmap.createBitmap(bmpW, bmpH, android.graphics.Bitmap.Config.ARGB_8888)
        val c = Canvas(bitmap)

        val path = android.graphics.Path().apply {
            moveTo(pad, pad)
            lineTo(pad, pad + h * 0.85f)
            lineTo(pad + w * 0.25f, pad + h * 0.65f)
            lineTo(pad + w * 0.5f, pad + h)
            lineTo(pad + w * 0.65f, pad + h * 0.92f)
            lineTo(pad + w * 0.4f, pad + h * 0.58f)
            lineTo(pad + w * 0.7f, pad + h * 0.58f)
            close()
        }

        // Shadow
        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.argb(80, 0, 0, 0)
            style = Paint.Style.FILL
            maskFilter = android.graphics.BlurMaskFilter(2f * density, android.graphics.BlurMaskFilter.Blur.NORMAL)
        }
        c.save()
        c.translate(1f * density, 1f * density)
        c.drawPath(path, shadowPaint)
        c.restore()

        // Fill
        c.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            style = Paint.Style.FILL
        })
        // Stroke
        c.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.BLACK
            style = Paint.Style.STROKE
            strokeWidth = 1f * density
            strokeJoin = Paint.Join.ROUND
        })

        setImageBitmap(bitmap)
        // Pivot at top-left so translation positions the cursor tip
        pivotX = 0f
        pivotY = 0f
        visibility = INVISIBLE

        android.view.Choreographer.getInstance().postFrameCallback(this)
    }

    fun setCursor(x: Float, y: Float) {
        targetX = x
        targetY = y
    }

    fun stop() {
        isRunning = false
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!isRunning) return

        val tx = targetX
        val ty = targetY
        if (tx >= 0 && ty >= 0) {
            // No interpolation — direct position tracking like iOS.
            // Smoothness comes from high refresh rate rendering, not lerp.
            translationX = tx
            translationY = ty
            if (visibility != VISIBLE) visibility = VISIBLE
        }

        android.view.Choreographer.getInstance().postFrameCallback(this)
    }
}
