package com.peariscope.network

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.peariscope.bridge.*

/**
 * High-level manager that coordinates the Pear runtime for P2P networking.
 * Port of NetworkManager.swift — viewer-only for Android.
 */
class NetworkManager(private val context: Context) {

    val bridge = BareWorkletBridge()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val prefs: SharedPreferences = context.getSharedPreferences("peariscope", Context.MODE_PRIVATE)

    // Observable state
    var isConnected = false
        private set
    var isConnecting = false
        private set
    var lastError: String? = null
    var connectedPeers = mutableListOf<PeerState>()
        private set

    // OTA update state
    enum class OtaStatus {
        IDLE, DOWNLOADING, READY, APPLIED, FAILED
    }
    var otaStatus = OtaStatus.IDLE
        private set
    var otaVersion: String? = null
        private set
    var otaError: String? = null
        private set

    // Hosting state
    var isHosting = false
        private set
    var hostConnectionCode: String? = null
        private set

    // Stream IDs of peers blocked from sending input/control/audio (pending PIN verification)
    val blockedStreamIds = mutableSetOf<Int>()

    // Callbacks
    var onConnectionStateChanged: (() -> Unit)? = null
    var onVideoData: ((ByteArray) -> Unit)? = null
    var onAudioData: ((ByteArray) -> Unit)? = null
    var onControlData: ((ByteArray) -> Unit)? = null
    var onInputData: ((ByteArray) -> Unit)? = null
    var onPeerConnected: ((PeerState) -> Unit)? = null
    var onPeerDisconnected: ((PeerState) -> Unit)? = null
    var onLookupResult: ((String, Boolean) -> Unit)? = null
    var onHostingStarted: ((String) -> Unit)? = null  // connectionCode
    var onHostingStopped: (() -> Unit)? = null
    var onHostPeerConnected: ((PeerState) -> Unit)? = null
    var onHostPeerDisconnected: ((PeerState) -> Unit)? = null

    private var pendingControlData = mutableListOf<ByteArray>()
    var lastConnectionCode: String? = null
        private set
    private var suppressConnections = false

    data class PeerState(
        val id: String,
        val name: String,
        val streamId: Int
    )

    init {
        setupBridgeCallbacks()
    }

    private fun setupBridgeCallbacks() {
        bridge.onHostingStarted = { event ->
            mainHandler.post {
                isHosting = true
                hostConnectionCode = event.connectionCode
                onHostingStarted?.invoke(event.connectionCode)
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onHostingStopped = {
            mainHandler.post {
                isHosting = false
                hostConnectionCode = null
                onHostingStopped?.invoke()
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onPeerConnected = { event ->
            mainHandler.post {
                val peer = PeerState(
                    id = event.peerKeyHex,
                    name = event.peerName,
                    streamId = event.streamId
                )
                if (isHosting) {
                    // In host mode, route to host callbacks
                    onHostPeerConnected?.invoke(peer)
                } else {
                    if (suppressConnections) return@post
                    connectedPeers.add(peer)
                    isConnected = true
                    isConnecting = false
                    onPeerConnected?.invoke(peer)
                }
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onPeerDisconnected = { event ->
            mainHandler.post {
                val peer = connectedPeers.firstOrNull { it.id == event.peerKeyHex }
                    ?: PeerState(event.peerKeyHex, "", 0)
                if (isHosting) {
                    onHostPeerDisconnected?.invoke(peer)
                } else {
                    connectedPeers.removeAll { it.id == event.peerKeyHex }
                    isConnected = connectedPeers.isNotEmpty()
                    onPeerDisconnected?.invoke(peer)
                }
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onConnectionEstablished = { event ->
            mainHandler.post {
                isConnected = true
                isConnecting = false
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onConnectionFailed = { event ->
            mainHandler.post {
                lastError = "Connection failed: ${event.reason}"
                isConnecting = false
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onStreamData = { event ->
            val ch = event.channel.toInt() and 0xFF
            when (ch) {
                0 -> onVideoData?.invoke(event.data)
                1, 2, 3 -> {
                    // Block input/control/audio from unverified peers (pending PIN)
                    if (event.streamId in blockedStreamIds) return@let
                    when (ch) {
                        1 -> onInputData?.invoke(event.data)
                        2 -> {
                            mainHandler.post {
                                val cb = onControlData
                                if (cb != null) {
                                    cb(event.data)
                                } else {
                                    pendingControlData.add(event.data)
                                }
                            }
                        }
                        3 -> onAudioData?.invoke(event.data)
                    }
                }
            }
        }

        bridge.onCh0VideoData = { data ->
            onVideoData?.invoke(data)
        }

        bridge.onError = { msg ->
            Log.e(TAG, "Bridge error: $msg")
            mainHandler.post {
                lastError = msg
                onConnectionStateChanged?.invoke()
            }
        }

        bridge.onLog = { msg ->
            Log.d(TAG, "Worklet: $msg")
        }

        bridge.onLookupResult = { code, online ->
            onLookupResult?.invoke(code, online)
        }

        // DHT node caching for faster bootstrap
        bridge.onDhtNodes = { nodes ->
            try {
                val json = org.json.JSONArray()
                for (node in nodes) {
                    val obj = org.json.JSONObject()
                    obj.put("host", node["host"])
                    obj.put("port", node["port"])
                    if (node.containsKey("lastSeen")) obj.put("lastSeen", node["lastSeen"])
                    json.put(obj)
                }
                prefs.edit().putString("dhtNodes", json.toString()).apply()
                Log.d(TAG, "Cached ${nodes.size} DHT nodes")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to cache DHT nodes", e)
            }
        }

        // OTA worklet update
        bridge.onOtaUpdate = { version, bundleData ->
            mainHandler.post {
                otaStatus = OtaStatus.DOWNLOADING
                otaVersion = version
                onConnectionStateChanged?.invoke()
            }
            Log.d(TAG, "OTA update received: v$version, ${bundleData.size} bytes")
            try {
                val bundleFile = java.io.File(context.filesDir, "worklet-ota.bundle")
                val versionFile = java.io.File(context.filesDir, "worklet-ota.version")
                bundleFile.writeBytes(bundleData)
                versionFile.writeText(version)
                Log.d(TAG, "OTA bundle saved to ${bundleFile.absolutePath}")
                mainHandler.post {
                    otaStatus = OtaStatus.READY
                    onConnectionStateChanged?.invoke()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to save OTA bundle", e)
                mainHandler.post {
                    otaStatus = OtaStatus.FAILED
                    otaError = e.message
                    onConnectionStateChanged?.invoke()
                }
            }
        }
    }

    /**
     * Start the Bare worklet runtime.
     * Loads worklet.bundle from assets and initializes BareKit.
     */
    fun startRuntime() {
        if (bridge.isAlive) return
        Log.d(TAG, "Starting Bare runtime...")

        try {
            val bundleData: ByteArray
            val otaBundleFile = java.io.File(context.filesDir, "worklet-ota.bundle")
            val otaVersionFile = java.io.File(context.filesDir, "worklet-ota.version")

            if (otaBundleFile.exists() && otaBundleFile.length() > 10000) {
                // Load OTA bundle
                bundleData = otaBundleFile.readBytes()
                val version = if (otaVersionFile.exists()) otaVersionFile.readText() else "unknown"
                Log.d(TAG, "Loading OTA worklet bundle v$version (${bundleData.size} bytes)")
            } else {
                // Fall back to built-in assets bundle
                bundleData = context.assets.open("worklet.bundle").use { it.readBytes() }
                Log.d(TAG, "Loading built-in worklet bundle (${bundleData.size} bytes)")
            }

            bridge.start(context, bundleData)
            Log.d(TAG, "Bare runtime started (${bundleData.size} bytes)")

            // Check if we loaded an OTA bundle
            if (otaBundleFile.exists() && otaBundleFile.length() > 10000 && otaVersionFile.exists()) {
                val ver = otaVersionFile.readText()
                mainHandler.post {
                    otaStatus = OtaStatus.APPLIED
                    otaVersion = ver
                    onConnectionStateChanged?.invoke()
                    // Auto-dismiss after 8 seconds
                    mainHandler.postDelayed({
                        if (otaStatus == OtaStatus.APPLIED) {
                            otaStatus = OtaStatus.IDLE
                            onConnectionStateChanged?.invoke()
                        }
                    }, 8000)
                }
            }

            // Send cached DHT nodes for faster bootstrap
            sendCachedDhtNodes()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Bare runtime", e)
        }
    }

    private fun sendCachedDhtNodes() {
        val json = prefs.getString("dhtNodes", null) ?: return
        try {
            val arr = org.json.JSONArray(json)
            val nodes = mutableListOf<Map<String, Any>>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                nodes.add(mapOf(
                    "host" to obj.getString("host"),
                    "port" to obj.getInt("port")
                ))
            }
            if (nodes.isNotEmpty()) {
                bridge.sendCachedDhtNodes(nodes)
                Log.d(TAG, "Sent ${nodes.size} cached DHT nodes to worklet")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send cached DHT nodes", e)
        }
    }

    fun startHosting(deviceCode: String? = null) {
        if (!bridge.isAlive) startRuntime()
        bridge.startHosting(deviceCode)
    }

    fun stopHosting() {
        bridge.stopHosting()
        isHosting = false
        hostConnectionCode = null
    }

    fun connect(code: String) {
        // Stop hosting before connecting as viewer — prevents crossed connections
        // where both sides see each other as peers and send PIN challenges.
        if (isHosting) {
            Log.d(TAG, "Stopping hosting before connecting as viewer")
            stopHosting()
        }

        // Clean up stale state from previous connections/hosting before starting new one.
        // Without this, the JS worklet may still have old swarm topics joined,
        // causing it to reconnect to the OLD peer instead of finding the new one.
        if (bridge.isAlive) {
            bridge.disconnect(peerKeyHex = "*")
        }
        connectedPeers.clear()
        isConnected = false

        suppressConnections = false
        lastConnectionCode = code
        isConnecting = true
        onConnectionStateChanged?.invoke()

        if (!bridge.isAlive) {
            startRuntime()
        }

        bridge.connectToPeer(code)

        // Save to recent hosts
        SavedHosts.save(prefs, code)
    }

    fun disconnectAll() {
        lastConnectionCode = null
        suppressConnections = true
        pendingControlData.clear()
        for (peer in connectedPeers) {
            bridge.disconnect(peerKeyHex = peer.id)
        }
        connectedPeers.clear()
        isConnected = false
        isConnecting = false
        onConnectionStateChanged?.invoke()
    }

    fun sendControlData(data: ByteArray, streamId: Int) {
        bridge.sendStreamData(streamId, channel = 2, data = data)
    }

    fun sendInputData(data: ByteArray, streamId: Int) {
        bridge.sendStreamData(streamId, channel = 1, data = data)
    }

    fun suspendNetworking() {
        bridge.sendSuspendSwarm()
        Log.d(TAG, "Sent swarm suspend to worklet")
    }

    fun resumeNetworking() {
        bridge.sendResumeSwarm()
        Log.d(TAG, "Sent swarm resume to worklet")
        // The worklet RESUME handler already calls reannounce(), but send an
        // explicit one as belt-and-suspenders after a short delay to ensure
        // the swarm has fully resumed before re-announcing.
        if (isHosting) {
            mainHandler.postDelayed({
                if (isHosting) {
                    bridge.sendReannounce()
                    Log.d(TAG, "Sent reannounce after resume (hosting)")
                }
            }, 2000)
        }
    }

    /** Start monitoring network changes to re-announce DHT topic when connectivity changes. */
    fun startNetworkMonitor() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    if (isHosting) {
                        Log.d(TAG, "Network available, re-announcing DHT topic")
                        bridge.sendReannounce()
                    }
                }
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                mainHandler.post {
                    if (isHosting) {
                        Log.d(TAG, "Network capabilities changed, re-announcing DHT topic")
                        bridge.sendReannounce()
                    }
                }
            }
        })
    }

    fun shutdown() {
        bridge.terminate()
    }

    fun setControlDataCallback(callback: ((ByteArray) -> Unit)?) {
        onControlData = callback
        if (callback != null && pendingControlData.isNotEmpty()) {
            val buffered = ArrayList(pendingControlData)
            pendingControlData.clear()
            for (data in buffered) {
                callback(data)
            }
        } else if (callback == null) {
            pendingControlData.clear()
        }
    }

    companion object {
        private const val TAG = "NetworkManager"
    }
}

/**
 * Persisted saved hosts (recent connections).
 */
object SavedHosts {
    private const val KEY = "savedHosts"

    data class Host(
        val code: String,
        val name: String,
        val lastConnected: Long,
        val pinned: Boolean = false
    )

    fun loadAll(prefs: SharedPreferences): List<Host> {
        val json = prefs.getString(KEY, null) ?: return emptyList()
        return try {
            val arr = org.json.JSONArray(json)
            val hosts = mutableListOf<Host>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                hosts.add(Host(
                    code = obj.getString("code"),
                    name = obj.optString("name", obj.getString("code")),
                    lastConnected = obj.optLong("lastConnected", 0),
                    pinned = obj.optBoolean("pinned", false)
                ))
            }
            hosts.sortedWith(compareByDescending<Host> { it.pinned }.thenByDescending { it.lastConnected })
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun save(prefs: SharedPreferences, code: String, name: String? = null) {
        val hosts = loadAll(prefs).toMutableList()
        val upperCode = code.uppercase()
        val existing = hosts.firstOrNull { it.code.uppercase() == upperCode }
        hosts.removeAll { it.code.uppercase() == upperCode }
        val host = Host(
            code = upperCode,
            name = name ?: existing?.name ?: upperCode,
            lastConnected = System.currentTimeMillis(),
            pinned = existing?.pinned ?: false
        )
        hosts.add(0, host)
        if (hosts.size > 10) hosts.subList(10, hosts.size).clear()

        val arr = org.json.JSONArray()
        for (h in hosts) {
            val obj = org.json.JSONObject()
            obj.put("code", h.code)
            obj.put("name", h.name)
            obj.put("lastConnected", h.lastConnected)
            obj.put("pinned", h.pinned)
            arr.put(obj)
        }
        prefs.edit().putString(KEY, arr.toString()).apply()
    }

    fun remove(prefs: SharedPreferences, code: String) {
        val hosts = loadAll(prefs).toMutableList()
        hosts.removeAll { it.code.uppercase() == code.uppercase() }
        val arr = org.json.JSONArray()
        for (h in hosts) {
            val obj = org.json.JSONObject()
            obj.put("code", h.code)
            obj.put("name", h.name)
            obj.put("lastConnected", h.lastConnected)
            obj.put("pinned", h.pinned)
            arr.put(obj)
        }
        prefs.edit().putString(KEY, arr.toString()).apply()
    }

    fun togglePin(prefs: SharedPreferences, code: String) {
        val hosts = loadAll(prefs).toMutableList()
        val idx = hosts.indexOfFirst { it.code.uppercase() == code.uppercase() }
        if (idx >= 0) {
            val h = hosts[idx]
            hosts[idx] = h.copy(pinned = !h.pinned)
            val arr = org.json.JSONArray()
            for (host in hosts) {
                val obj = org.json.JSONObject()
                obj.put("code", host.code)
                obj.put("name", host.name)
                obj.put("lastConnected", host.lastConnected)
                obj.put("pinned", host.pinned)
                arr.put(obj)
            }
            prefs.edit().putString(KEY, arr.toString()).apply()
        }
    }

    fun rename(prefs: SharedPreferences, code: String, newName: String) {
        val hosts = loadAll(prefs).toMutableList()
        val idx = hosts.indexOfFirst { it.code.uppercase() == code.uppercase() }
        if (idx >= 0) {
            hosts[idx] = hosts[idx].copy(name = newName)
            val arr = org.json.JSONArray()
            for (h in hosts) {
                val obj = org.json.JSONObject()
                obj.put("code", h.code)
                obj.put("name", h.name)
                obj.put("lastConnected", h.lastConnected)
                obj.put("pinned", h.pinned)
                arr.put(obj)
            }
            prefs.edit().putString(KEY, arr.toString()).apply()
        }
    }
}
