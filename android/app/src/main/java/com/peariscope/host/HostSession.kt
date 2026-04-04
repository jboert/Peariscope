package com.peariscope.host

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.peariscope.bridge.PeerConnectedEvent
import com.peariscope.network.NetworkManager

/**
 * Orchestrates the host-side pipeline: capture → encode → stream.
 * Capture runs inside MediaProjectionService so it survives backgrounding.
 */
class HostSession(
    private val context: Context,
    private val networkManager: NetworkManager
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val prefs = context.getSharedPreferences("peariscope", Context.MODE_PRIVATE)

    // State
    var isActive = false
        private set
    var connectionCode: String? = null
        private set
    var connectedViewers = mutableListOf<NetworkManager.PeerState>()
        private set
    var fps = 0
        private set
    var requirePin = true
    var pinCode: String = prefs.getString("hostPin", null) ?: generatePin().also {
        prefs.edit().putString("hostPin", it).apply()
    }
    var pendingPeer: NetworkManager.PeerState? = null
        private set
    private val approvedPeerIds = mutableSetOf<String>()

    // Callbacks
    var onStateChanged: (() -> Unit)? = null

    private var frameCount = 0
    private var lastFpsTime = System.currentTimeMillis()

    /**
     * Start the foreground service and pass the MediaProjection result.
     * The service owns the projection — it survives app backgrounding.
     */
    fun initializeCapture(resultCode: Int, data: Intent) {
        val serviceIntent = Intent(context, MediaProjectionService::class.java).apply {
            putExtra(MediaProjectionService.EXTRA_RESULT_CODE, resultCode)
            putExtra(MediaProjectionService.EXTRA_RESULT_DATA, data)
        }
        context.startForegroundService(serviceIntent)
    }

    /**
     * Start hosting — begins listening for peers on the DHT.
     * Call initializeCapture() first.
     */
    fun start() {
        if (isActive) return
        Log.d(TAG, "Starting host session")

        networkManager.startRuntime()
        setupNetworkCallbacks()

        val savedCode = prefs.getString("hostConnectionCode", null)
        networkManager.startHosting(deviceCode = savedCode)
        isActive = true
        notifyStateChanged()
    }

    fun updatePin(newPin: String) {
        pinCode = newPin
        prefs.edit().putString("hostPin", newPin).apply()
        Log.d(TAG, "PIN updated")
    }

    fun regenerateCode() {
        if (!isActive) return
        Log.d(TAG, "Regenerating connection code")
        networkManager.stopHosting()
        connectionCode = null
        prefs.edit().remove("hostConnectionCode").apply()
        notifyStateChanged()
        networkManager.startHosting(deviceCode = null)
    }

    fun stop() {
        if (!isActive) return
        Log.d(TAG, "Stopping host session")

        stopCapture()
        networkManager.stopHosting()
        connectedViewers.clear()
        networkManager.blockedStreamIds.clear()
        connectionCode = null
        isActive = false
        fps = 0
        notifyStateChanged()

        try {
            context.stopService(Intent(context, MediaProjectionService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Failed to stop projection service", e)
        }
    }

    private fun setupNetworkCallbacks() {
        networkManager.onHostingStarted = { code ->
            mainHandler.post {
                connectionCode = code
                prefs.edit().putString("hostConnectionCode", code).apply()
                Log.d(TAG, "Hosting started, code: $code")
                notifyStateChanged()
            }
        }

        networkManager.onHostingStopped = {
            mainHandler.post {
                isActive = false
                connectionCode = null
                stopCapture()
                notifyStateChanged()
            }
        }

        networkManager.onHostPeerConnected = { peer ->
            mainHandler.post {
                // Auto-approve previously verified peers on reconnect
                val skipPinOnReconnect = prefs.getBoolean("skipPinOnReconnect", false)
                if (skipPinOnReconnect && approvedPeerIds.contains(peer.id)) {
                    Log.d(TAG, "Auto-approving previously verified peer: ${peer.id.take(16)}")
                    approvePeer(peer)
                    return@post
                }
                if (requirePin && pinCode.isNotEmpty()) {
                    pendingPeer = peer
                    // Block input/control/audio from this peer until PIN verified
                    networkManager.blockedStreamIds.add(peer.streamId)
                    try {
                        val challenge = com.peariscope.proto.PeariscopeProto.PeerChallenge.newBuilder()
                            .setPin(pinCode)
                            .setPeerKey(com.google.protobuf.ByteString.copyFrom(hexToBytes(peer.id)))
                            .build()
                        val control = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                            .setPeerChallenge(challenge)
                            .build()
                        networkManager.sendControlData(control.toByteArray(), peer.streamId)
                        Log.d(TAG, "Sent PIN challenge to peer: ${peer.id.take(16)}")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to send PIN challenge", e)
                    }
                    notifyStateChanged()
                } else {
                    approvePeer(peer)
                }
            }
        }

        networkManager.onHostPeerDisconnected = { peer ->
            mainHandler.post {
                connectedViewers.removeAll { it.id == peer.id }
                networkManager.blockedStreamIds.remove(peer.streamId)
                if (pendingPeer?.id == peer.id) pendingPeer = null
                Log.d(TAG, "Viewer disconnected: ${peer.id.take(16)}, remaining: ${connectedViewers.size}")
                if (connectedViewers.isEmpty()) {
                    stopCapture()
                }
                notifyStateChanged()
            }
        }

        networkManager.onControlData = { data ->
            mainHandler.post {
                try {
                    val control = com.peariscope.proto.PeariscopeProto.ControlMessage.parseFrom(data)
                    when {
                        control.hasPeerChallengeResponse() -> {
                            val response = control.peerChallengeResponse
                            Log.d(TAG, "PIN response: accepted=${response.accepted} pin='${response.pin}' expected='$pinCode'")
                            if (response.accepted && response.pin == pinCode) {
                                val peer = pendingPeer
                                if (peer != null) {
                                    val confirm = com.peariscope.proto.PeariscopeProto.PeerChallengeResponse.newBuilder()
                                        .setAccepted(true).build()
                                    val confirmControl = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                                        .setPeerChallengeResponse(confirm).build()
                                    networkManager.sendControlData(confirmControl.toByteArray(), peer.streamId)
                                    approvePeer(peer)
                                }
                            } else {
                                val peer = pendingPeer
                                if (peer != null) {
                                    val reject = com.peariscope.proto.PeariscopeProto.PeerChallengeResponse.newBuilder()
                                        .setAccepted(false).build()
                                    val rejectControl = com.peariscope.proto.PeariscopeProto.ControlMessage.newBuilder()
                                        .setPeerChallengeResponse(reject).build()
                                    networkManager.sendControlData(rejectControl.toByteArray(), peer.streamId)
                                }
                            }
                        }
                        control.hasRequestIdr() -> {
                            MediaProjectionService.instance?.requestKeyframe()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to parse control message", e)
                }
            }
        }

        var inputCount = 0
        // Track drag state: button down position → accumulate moves → swipe on button up
        var isDragging = false
        var dragStartX = 0f
        var dragStartY = 0f
        var dragLastX = 0f
        var dragLastY = 0f

        networkManager.onInputData = inputHandler@{ data ->
            try {
                val inputEvent = com.peariscope.proto.PeariscopeProto.InputEvent.parseFrom(data)
                inputCount++
                val injector = com.peariscope.input.InputInjectorService.instance
                if (injector == null) {
                    if (inputCount <= 5) Log.w(TAG, "Input #$inputCount: AccessibilityService not running, dropping")
                    return@inputHandler
                }
                when {
                    inputEvent.hasMouseButton() -> {
                        val btn = inputEvent.mouseButton
                        if (btn.button == 0) {
                            if (btn.pressed) {
                                // Button down — start tracking potential drag
                                isDragging = true
                                dragStartX = btn.x
                                dragStartY = btn.y
                                dragLastX = btn.x
                                dragLastY = btn.y
                            } else {
                                // Button up — check if it was a drag or a tap
                                if (isDragging) {
                                    val dx = Math.abs(dragLastX - dragStartX)
                                    val dy = Math.abs(dragLastY - dragStartY)
                                    if (dx > 0.02f || dy > 0.02f) {
                                        // Drag distance > 2% of screen — inject swipe
                                        injector.injectSwipe(dragStartX, dragStartY, dragLastX, dragLastY)
                                    } else {
                                        // Small movement — inject tap at original position
                                        injector.injectTap(dragStartX, dragStartY)
                                    }
                                }
                                isDragging = false
                            }
                        } else if (btn.pressed && btn.button == 1) {
                            injector.injectLongPress(btn.x, btn.y)
                        }
                    }
                    inputEvent.hasMouseMove() -> {
                        if (isDragging) {
                            dragLastX = inputEvent.mouseMove.x
                            dragLastY = inputEvent.mouseMove.y
                        }
                    }
                    inputEvent.hasScroll() -> {
                        val scroll = inputEvent.scroll
                        // Convert scroll deltas to swipe gesture
                        val cx = 0.5f  // center of screen
                        val cy = 0.5f
                        val swipeScale = 0.15f  // scroll sensitivity
                        val toX = cx - scroll.deltaX * swipeScale
                        val toY = cy - scroll.deltaY * swipeScale
                        injector.injectSwipe(cx, cy, toX, toY, durationMs = 200)
                    }
                    inputEvent.hasKey() -> {
                        Log.d(TAG, "Input #$inputCount: key code=${inputEvent.key.keycode} pressed=${inputEvent.key.pressed}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to decode input event: ${e.message}, data=${data.size} bytes")
            }
        }
    }

    fun approvePeer(peer: NetworkManager.PeerState) {
        connectedViewers.add(peer)
        approvedPeerIds.add(peer.id)
        pendingPeer = null
        networkManager.blockedStreamIds.remove(peer.streamId)
        networkManager.bridge.sendApprovePeer(peer.id)
        Log.d(TAG, "Viewer approved: ${peer.id.take(16)}, total: ${connectedViewers.size}")

        if (connectedViewers.size == 1) {
            startCapture()
        } else {
            MediaProjectionService.instance?.requestKeyframe()
        }
        notifyStateChanged()
    }

    fun rejectPeer() {
        val peer = pendingPeer ?: return
        pendingPeer = null
        networkManager.blockedStreamIds.remove(peer.streamId)
        networkManager.bridge.disconnect(peerKeyHex = peer.id)
        notifyStateChanged()
    }

    private fun startCapture() {
        val service = MediaProjectionService.instance
        if (service == null) {
            Log.e(TAG, "MediaProjectionService not running, cannot start capture")
            return
        }

        val enc = service.startCapture { data, isKeyframe ->
            for (viewer in connectedViewers) {
                try {
                    networkManager.bridge.sendStreamData(viewer.streamId, channel = 0, data = data)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send video to ${viewer.id.take(8)}", e)
                }
            }

            frameCount++
            val nowMs = System.currentTimeMillis()
            if (nowMs - lastFpsTime >= 1000) {
                fps = frameCount
                frameCount = 0
                lastFpsTime = nowMs
                mainHandler.post { notifyStateChanged() }
            }
        }

        if (enc != null) {
            Log.d(TAG, "Capture pipeline started: ${service.screenWidth}x${service.screenHeight}")

            // Periodic keyframe every 500ms — frequent keyframes reduce artifacting
            // when P-frames are dropped by the rate limiter. Higher bandwidth but
            // artifacts clear within 500ms instead of lingering for seconds.
            mainHandler.post(object : Runnable {
                override fun run() {
                    if (isActive && MediaProjectionService.instance != null) {
                        MediaProjectionService.instance?.requestKeyframe()
                        mainHandler.postDelayed(this, 500)
                    }
                }
            })
        }
    }

    private fun stopCapture() {
        MediaProjectionService.instance?.stopCapture()
        fps = 0
        Log.d(TAG, "Capture pipeline stopped")
    }

    fun release() {
        stop()
    }

    private fun notifyStateChanged() {
        onStateChanged?.invoke()
    }

    companion object {
        private const val TAG = "HostSession"

        private fun generatePin(): String {
            val random = java.security.SecureRandom()
            return String.format("%06d", random.nextInt(1000000))
        }

        private fun hexToBytes(hex: String): ByteArray {
            val len = hex.length
            val data = ByteArray(len / 2)
            var i = 0
            while (i < len) {
                data[i / 2] = ((Character.digit(hex[i], 16) shl 4) + Character.digit(hex[i + 1], 16)).toByte()
                i += 2
            }
            return data
        }
    }
}
