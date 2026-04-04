package com.peariscope.bridge

import android.content.Context
import android.util.Log
import to.holepunch.bare.kit.IPC
import to.holepunch.bare.kit.Worklet
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Bridge between Kotlin and the Pear runtime (Bare + Hyperswarm) running in a BareWorklet.
 * Port of BareWorkletBridge.swift — same IPC protocol:
 * 4-byte BE length prefix + 1-byte msg type + payload.
 */
class BareWorkletBridge {

    // Message types sent from native to the JS worklet
    private object NativeToWorklet {
        const val START_HOSTING: Byte = 0x01
        const val STOP_HOSTING: Byte = 0x02
        const val CONNECT_TO_PEER: Byte = 0x03
        const val DISCONNECT: Byte = 0x04
        const val STREAM_DATA: Byte = 0x05
        const val STATUS_REQUEST: Byte = 0x06
        const val LOOKUP_PEER: Byte = 0x07
        const val CACHED_DHT_NODES: Byte = 0x08
        const val SUSPEND_SWARM: Byte = 0x09
        const val RESUME_SWARM: Byte = 0x0A
        const val APPROVE_PEER: Byte = 0x0B
        const val REANNOUNCE: Byte = 0x0D
    }

    // Message types received from the JS worklet
    private object WorkletToNative {
        const val HOSTING_STARTED: Byte = 0x81.toByte()
        const val HOSTING_STOPPED: Byte = 0x82.toByte()
        const val CONNECTION_ESTABLISHED: Byte = 0x83.toByte()
        const val CONNECTION_FAILED: Byte = 0x84.toByte()
        const val PEER_CONNECTED: Byte = 0x85.toByte()
        const val PEER_DISCONNECTED: Byte = 0x86.toByte()
        const val STREAM_DATA: Byte = 0x87.toByte()
        const val STATUS_RESPONSE: Byte = 0x88.toByte()
        const val ERROR: Byte = 0x89.toByte()
        const val LOG: Byte = 0x8A.toByte()
        const val LOOKUP_RESULT: Byte = 0x8B.toByte()
        const val DHT_NODES: Byte = 0x8C.toByte()
        const val OTA_UPDATE_AVAILABLE: Byte = 0x8D.toByte()
        const val CONNECTION_STATE: Byte = 0x8E.toByte()
    }

    // IPC state — protected by recvLock
    private var recvBuf = ByteArray(0)
    private var recvBufOffset = 0
    private val recvLock = ReentrantLock()

    // Chunk assembly
    private val chunkBuffers = HashMap<String, ChunkBuffer>()
    private var chunkAssembledCount = 0
    private var orphanedChunkCount = 0
    var ipcReadCount = 0
        private set

    // Channel 0 time gate
    private var lastCh0AcceptTime = 0L
    private var ch0DropCount = 0
    private var lastCh0FrameAccepted = true
    private val ch0MinIntervalNs = (1_000_000_000L / 61) // ~16.4ms

    // Pending video data — delivered outside recvLock
    private val pendingVideoData = ArrayList<ByteArray>()

    // Write state
    private val writeLock = ReentrantLock()
    private var pendingWrite = ByteArray(0)
    private var droppedFrameCount = 0

    // BareKit worklet and IPC
    private var worklet: Worklet? = null
    private var ipc: IPC? = null

    val isAlive: Boolean get() = worklet != null && ipc != null

    // Callbacks
    var onHostingStarted: ((HostingStartedEvent) -> Unit)? = null
    var onHostingStopped: (() -> Unit)? = null
    var onConnectionEstablished: ((ConnectionEstablishedEvent) -> Unit)? = null
    var onConnectionFailed: ((ConnectionFailedEvent) -> Unit)? = null
    var onPeerConnected: ((PeerConnectedEvent) -> Unit)? = null
    var onPeerDisconnected: ((PeerDisconnectedEvent) -> Unit)? = null
    var onStreamData: ((StreamDataEvent) -> Unit)? = null
    var onCh0VideoData: ((ByteArray) -> Unit)? = null
    var onStatusResponse: ((StatusEvent) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null
    var onLookupResult: ((String, Boolean) -> Unit)? = null
    var onDhtNodes: ((List<Map<String, Any>>) -> Unit)? = null
    var onOtaUpdate: ((String, ByteArray) -> Unit)? = null
    var onConnectionState: ((String) -> Unit)? = null

    /**
     * Start the Bare worklet with the packed Pear networking bundle.
     * @param context Android context for asset resolution
     * @param bundleData UTF-8 bytes of the worklet.bundle file
     */
    fun start(context: Context, bundleData: ByteArray) {
        val opts = Worklet.Options()
        // Assets path for resolving linked native addons
        opts.assets = context.applicationInfo.nativeLibraryDir

        val w = Worklet(opts)
        worklet = w

        // Start worklet with bundle source
        val bundleStr = String(bundleData, Charsets.UTF_8)
        w.start("/worklet.bundle", bundleStr, Charsets.UTF_8, null)
        Log.d(TAG, "Worklet started (${bundleData.size} bytes)")

        // Create IPC after start — pipe fds are only valid after worklet starts
        val bareIpc = IPC(w)
        ipc = bareIpc

        // Read IPC data in the readable callback
        bareIpc.readable {
            recvLock.withLock {
                var readsThisBatch = 0
                while (readsThisBatch < 50) {
                    val data = bareIpc.read() ?: break
                    readsThisBatch++
                    ipcReadCount++

                    // Memory pressure: skip complete frames to maintain alignment
                    if (recvBuf.size - recvBufOffset > 2_000_000) {
                        var skipped = 0
                        while (recvBufOffset + 5 <= recvBuf.size) {
                            val frameLen = ((recvBuf[recvBufOffset].toInt() and 0xFF) shl 24) or
                                           ((recvBuf[recvBufOffset + 1].toInt() and 0xFF) shl 16) or
                                           ((recvBuf[recvBufOffset + 2].toInt() and 0xFF) shl 8) or
                                           (recvBuf[recvBufOffset + 3].toInt() and 0xFF)
                            if (frameLen <= 0 || frameLen > 1_000_000) {
                                // Corrupt — reset (accept alignment loss as last resort)
                                recvBuf = ByteArray(0)
                                recvBufOffset = 0
                                break
                            }
                            if (recvBufOffset + 4 + frameLen > recvBuf.size) break
                            recvBufOffset += 4 + frameLen
                            skipped++
                        }
                        if (recvBufOffset > 0 && recvBuf.isNotEmpty()) {
                            recvBuf = recvBuf.copyOfRange(recvBufOffset, recvBuf.size)
                            recvBufOffset = 0
                        }
                        Log.d(TAG, "Overflow: skipped $skipped frames, recvBuf=${recvBuf.size}")
                        continue
                    }

                    // Append data to receive buffer
                    val bytes = ByteArray(data.remaining())
                    data.get(bytes)
                    val newBuf = ByteArray(recvBuf.size + bytes.size)
                    System.arraycopy(recvBuf, 0, newBuf, 0, recvBuf.size)
                    System.arraycopy(bytes, 0, newBuf, recvBuf.size, bytes.size)
                    recvBuf = newBuf

                    drainFrames()
                }
            }

            // Deliver video data outside the lock
            val videoToDeliver: List<ByteArray>
            val videoCb: ((ByteArray) -> Unit)?
            recvLock.withLock {
                videoToDeliver = ArrayList(pendingVideoData)
                pendingVideoData.clear()
                videoCb = onCh0VideoData
            }
            videoCb?.let { cb ->
                for (videoData in videoToDeliver) {
                    cb(videoData)
                }
            }
        }

        // Resume flushing pending writes when the pipe is ready
        bareIpc.writable {
            writeLock.withLock {
                flushPendingWrites()
            }
        }
    }

    // MARK: - Commands (native -> worklet)

    fun startHosting(deviceCode: String? = null) {
        if (deviceCode != null) {
            sendCommand(NativeToWorklet.START_HOSTING, json = mapOf("deviceCode" to deviceCode))
        } else {
            sendCommand(NativeToWorklet.START_HOSTING)
        }
    }

    fun stopHosting() {
        sendCommand(NativeToWorklet.STOP_HOSTING)
    }

    fun connectToPeer(code: String) {
        sendCommand(NativeToWorklet.CONNECT_TO_PEER, json = mapOf("code" to code))
    }

    fun disconnect(peerKeyHex: String) {
        sendCommand(NativeToWorklet.DISCONNECT, json = mapOf("peerKeyHex" to peerKeyHex))
    }

    fun sendStreamData(streamId: Int, channel: Int, data: ByteArray) {
        if (data.size <= MAX_CHUNK_PAYLOAD) {
            // Small frame — send directly
            val payload = ByteBuffer.allocate(7 + data.size).order(ByteOrder.BIG_ENDIAN)
            payload.putInt(streamId)
            payload.put(channel.toByte())
            payload.putShort(0) // totalChunks=0 (no chunking)
            payload.put(data)
            // Only apply backpressure to video (ch0), never drop control messages
            val forceWrite = channel != 0
            sendCommand(NativeToWorklet.STREAM_DATA, binary = payload.array(), forceWrite = forceWrite)
            return
        }

        // Split large data into chunks
        val totalChunks = (data.size + MAX_CHUNK_PAYLOAD - 1) / MAX_CHUNK_PAYLOAD
        for (i in 0 until totalChunks) {
            val offset = i * MAX_CHUNK_PAYLOAD
            val end = minOf(offset + MAX_CHUNK_PAYLOAD, data.size)
            val chunk = data.copyOfRange(offset, end)

            val payload = ByteBuffer.allocate(9 + chunk.size).order(ByteOrder.BIG_ENDIAN)
            payload.putInt(streamId)
            payload.put(channel.toByte())
            payload.putShort(totalChunks.toShort())
            payload.putShort(i.toShort())
            payload.put(chunk)
            val forceWrite = channel != 0
            sendCommand(NativeToWorklet.STREAM_DATA, binary = payload.array(), forceWrite = forceWrite)
        }
    }

    fun requestStatus() {
        sendCommand(NativeToWorklet.STATUS_REQUEST)
    }

    fun lookupPeer(code: String) {
        sendCommand(NativeToWorklet.LOOKUP_PEER, json = mapOf("code" to code))
    }

    fun sendCachedDhtNodes(nodes: List<Map<String, Any>>) {
        sendCommand(NativeToWorklet.CACHED_DHT_NODES, json = mapOf("nodes" to nodes))
    }

    fun sendSuspendSwarm() {
        sendCommand(NativeToWorklet.SUSPEND_SWARM)
    }

    fun sendResumeSwarm() {
        sendCommand(NativeToWorklet.RESUME_SWARM)
    }

    fun sendReannounce() {
        sendCommand(NativeToWorklet.REANNOUNCE)
    }

    fun sendApprovePeer(peerKeyHex: String) {
        sendCommand(NativeToWorklet.APPROVE_PEER, json = mapOf("peerKeyHex" to peerKeyHex))
    }

    fun terminate() {
        writeLock.withLock { pendingWrite = ByteArray(0) }
        worklet?.terminate()
        ipc?.close()
        worklet = null
        ipc = null
    }

    fun suspend() {
        worklet?.suspend()
    }

    fun resume() {
        worklet?.resume()
    }

    fun diagnosticSummary(): String {
        return "ipcReads=$ipcReadCount chunkBufs=${chunkBuffers.size} " +
            "assembled=$chunkAssembledCount orphaned=$orphanedChunkCount " +
            "dropped=$droppedFrameCount ch0gate=$ch0DropCount"
    }

    // MARK: - Frame encoding

    private fun sendCommand(type: Byte, json: Map<String, Any>? = null, binary: ByteArray? = null, forceWrite: Boolean = false) {
        val bareIpc = ipc ?: return

        val payloadBytes: ByteArray
        if (binary != null) {
            payloadBytes = ByteArray(1 + binary.size)
            payloadBytes[0] = type
            System.arraycopy(binary, 0, payloadBytes, 1, binary.size)
        } else if (json != null) {
            val jsonStr = jsonEncode(json)
            val jsonBytes = jsonStr.toByteArray(Charsets.UTF_8)
            payloadBytes = ByteArray(1 + jsonBytes.size)
            payloadBytes[0] = type
            System.arraycopy(jsonBytes, 0, payloadBytes, 1, jsonBytes.size)
        } else {
            payloadBytes = byteArrayOf(type)
        }

        val frame = ByteBuffer.allocate(4 + payloadBytes.size).order(ByteOrder.BIG_ENDIAN)
        frame.putInt(payloadBytes.size)
        frame.put(payloadBytes)

        writeLock.withLock {
            // Backpressure: drop video frames when write buffer is too full.
            // Never drop control messages (forceWrite) — PIN challenges etc must get through.
            if (!forceWrite && type == NativeToWorklet.STREAM_DATA && pendingWrite.size > MAX_PENDING_WRITE_BYTES) {
                droppedFrameCount++
                return
            }

            val newPending = ByteArray(pendingWrite.size + frame.array().size)
            System.arraycopy(pendingWrite, 0, newPending, 0, pendingWrite.size)
            System.arraycopy(frame.array(), 0, newPending, pendingWrite.size, frame.array().size)
            pendingWrite = newPending
            flushPendingWrites()
        }
    }

    private fun flushPendingWrites() {
        val bareIpc = ipc ?: return
        while (pendingWrite.isNotEmpty()) {
            val buf = ByteBuffer.wrap(pendingWrite)
            val written = bareIpc.write(buf)
            if (written <= 0) break
            if (written >= pendingWrite.size) {
                pendingWrite = ByteArray(0)
            } else {
                pendingWrite = pendingWrite.copyOfRange(written, pendingWrite.size)
            }
        }
    }

    // MARK: - Frame decoding

    private fun drainFrames() {
        while (recvBuf.size - recvBufOffset >= 4) {
            val buf = ByteBuffer.wrap(recvBuf, recvBufOffset, 4).order(ByteOrder.BIG_ENDIAN)
            val length = buf.int
            if (length > MAX_FRAME_LENGTH) {
                Log.e(TAG, "Frame length $length exceeds max $MAX_FRAME_LENGTH, dropping buffer")
                recvBuf = ByteArray(0)
                recvBufOffset = 0
                return
            }
            if (recvBuf.size - recvBufOffset < 4 + length) break

            val frameStart = recvBufOffset + 4
            val frameType = recvBuf[frameStart]

            if (frameType == WorkletToNative.STREAM_DATA) {
                handleStreamDataInPlace(frameStart, length)
            } else {
                val frame = recvBuf.copyOfRange(frameStart, frameStart + length)
                handleFrame(frame)
            }
            recvBufOffset += 4 + length
        }

        // Compact buffer
        if (recvBufOffset > 65536) {
            recvBuf = recvBuf.copyOfRange(recvBufOffset, recvBuf.size)
            recvBufOffset = 0
        }
    }

    private fun handleStreamDataInPlace(offset: Int, length: Int) {
        if (length < 3) return

        val restOffset = offset + 1
        val jsonLen = ByteBuffer.wrap(recvBuf, restOffset, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF

        if (jsonLen == 0) {
            // Binary format: [2B 0x0000] [4B streamId BE] [1B channel] [2B totalChunks BE] [2B chunkIndex BE] [payload]
            val restCount = length - 1
            if (restCount < 11) return
            val headerBase = restOffset + 2
            val streamId = ByteBuffer.wrap(recvBuf, headerBase, 4).order(ByteOrder.BIG_ENDIAN).int
            val channel = recvBuf[headerBase + 4]
            val totalChunks = ByteBuffer.wrap(recvBuf, headerBase + 5, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF
            val chunkIndex = ByteBuffer.wrap(recvBuf, headerBase + 7, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF
            val isChunked = totalChunks > 1
            val binaryStart = headerBase + 9
            val binaryEnd = offset + length
            processStreamData(streamId, channel, isChunked, totalChunks, chunkIndex, binaryStart, binaryEnd)
        } else {
            // Legacy JSON format
            val restCount = length - 1
            if (restCount < 2 + jsonLen) return
            val jsonData = recvBuf.copyOfRange(restOffset + 2, restOffset + 2 + jsonLen)
            val json = jsonDecode(String(jsonData, Charsets.UTF_8)) ?: return
            val streamId = (json["streamId"] as? Number)?.toInt() ?: 0
            val channel = ((json["channel"] as? Number)?.toInt() ?: 0).toByte()
            val totalChunks = (json["_totalChunks"] as? Number)?.toInt() ?: 0
            val isChunked = totalChunks > 1
            val chunkIndex = (json["_chunkIndex"] as? Number)?.toInt() ?: 0
            val binaryStart = restOffset + 2 + jsonLen
            val binaryEnd = offset + length
            processStreamData(streamId, channel.toInt(), isChunked, totalChunks, chunkIndex, binaryStart, binaryEnd)
        }
    }

    private fun processStreamData(
        streamId: Int, channel: Any, isChunked: Boolean,
        totalChunks: Int, chunkIndex: Int,
        binaryStart: Int, binaryEnd: Int
    ) {
        val ch = when (channel) {
            is Byte -> channel.toInt() and 0xFF
            is Int -> channel
            else -> 0
        }

        // Channel 0 time gate
        if (ch == 0) {
            val isChunk0 = isChunked && chunkIndex == 0
            if (!isChunked || isChunk0) {
                val now = System.nanoTime()
                if (now - lastCh0AcceptTime < ch0MinIntervalNs) {
                    ch0DropCount++
                    lastCh0FrameAccepted = false
                    return
                }
                lastCh0AcceptTime = now
                lastCh0FrameAccepted = true
            } else if (isChunked && !lastCh0FrameAccepted) {
                ch0DropCount++
                return
            }
        }

        if (isChunked) {
            val key = "$streamId:$ch"
            // Expire old chunk buffers
            if (chunkBuffers.size > MAX_PENDING_CHUNK_BUFFERS / 2) {
                val expired = chunkBuffers.entries.filter { it.value.isExpired() }
                expired.forEach { chunkBuffers.remove(it.key) }
            }
            if (chunkIndex == 0 && totalChunks <= MAX_CHUNKS_PER_BUFFER
                && chunkBuffers.size < MAX_PENDING_CHUNK_BUFFERS) {
                chunkBuffers[key] = ChunkBuffer(totalChunks)
            }
            val buf = chunkBuffers[key]
            if (buf == null || chunkIndex >= buf.total) {
                orphanedChunkCount++
                return
            }
            val binaryData = recvBuf.copyOfRange(binaryStart, binaryEnd)
            buf.add(chunkIndex, binaryData)
            if (buf.isComplete) {
                chunkAssembledCount++
                val assembled = buf.assemble()
                chunkBuffers.remove(key)
                if (ch == 0) {
                    pendingVideoData.add(assembled)
                }
                onStreamData?.invoke(StreamDataEvent(streamId, ch.toByte(), assembled))
            }
        } else {
            val binaryData = recvBuf.copyOfRange(binaryStart, binaryEnd)
            if (ch == 0) {
                pendingVideoData.add(binaryData)
            }
            onStreamData?.invoke(StreamDataEvent(streamId, ch.toByte(), binaryData))
        }
    }

    private fun handleFrame(frame: ByteArray) {
        if (frame.isEmpty()) return
        val type = frame[0]
        val rest = if (frame.size > 1) frame.copyOfRange(1, frame.size) else ByteArray(0)

        when (type) {
            WorkletToNative.HOSTING_STARTED -> {
                val json = parseJsonPayload(rest) ?: return
                onHostingStarted?.invoke(HostingStartedEvent(
                    publicKeyHex = json["publicKeyHex"] as? String ?: "",
                    connectionCode = json["connectionCode"] as? String ?: ""
                ))
            }
            WorkletToNative.HOSTING_STOPPED -> onHostingStopped?.invoke()
            WorkletToNative.CONNECTION_ESTABLISHED -> {
                val json = parseJsonPayload(rest) ?: return
                onConnectionEstablished?.invoke(ConnectionEstablishedEvent(
                    peerKeyHex = json["peerKeyHex"] as? String ?: "",
                    streamId = (json["streamId"] as? Number)?.toInt() ?: 0
                ))
            }
            WorkletToNative.CONNECTION_FAILED -> {
                val json = parseJsonPayload(rest) ?: return
                onConnectionFailed?.invoke(ConnectionFailedEvent(
                    code = json["code"] as? String ?: "",
                    reason = json["reason"] as? String ?: ""
                ))
            }
            WorkletToNative.PEER_CONNECTED -> {
                val json = parseJsonPayload(rest) ?: return
                onPeerConnected?.invoke(PeerConnectedEvent(
                    peerKeyHex = json["peerKeyHex"] as? String ?: "",
                    peerName = json["peerName"] as? String ?: "",
                    streamId = (json["streamId"] as? Number)?.toInt() ?: 0
                ))
            }
            WorkletToNative.PEER_DISCONNECTED -> {
                val json = parseJsonPayload(rest) ?: return
                onPeerDisconnected?.invoke(PeerDisconnectedEvent(
                    peerKeyHex = json["peerKeyHex"] as? String ?: "",
                    reason = json["reason"] as? String ?: ""
                ))
            }
            WorkletToNative.STREAM_DATA -> {
                // Fallback path for streamData not caught by in-place hot path
                if (rest.size < 2) return
                val jsonLen = ByteBuffer.wrap(rest, 0, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF
                if (jsonLen == 0) {
                    if (rest.size < 11) return
                    val streamId = ByteBuffer.wrap(rest, 2, 4).order(ByteOrder.BIG_ENDIAN).int
                    val channel = rest[6]
                    val totalChunks = ByteBuffer.wrap(rest, 7, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF
                    val chunkIndex = ByteBuffer.wrap(rest, 9, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF
                    val binaryData = rest.copyOfRange(11, rest.size)
                    deliverStreamData(streamId, channel, totalChunks > 1, totalChunks, chunkIndex, binaryData)
                } else {
                    if (rest.size < 2 + jsonLen) return
                    val jsonData = rest.copyOfRange(2, 2 + jsonLen)
                    val json = jsonDecode(String(jsonData, Charsets.UTF_8)) ?: return
                    val streamId = (json["streamId"] as? Number)?.toInt() ?: 0
                    val channel = ((json["channel"] as? Number)?.toInt() ?: 0).toByte()
                    val totalChunks = (json["_totalChunks"] as? Number)?.toInt() ?: 0
                    val chunkIndex = (json["_chunkIndex"] as? Number)?.toInt() ?: 0
                    val binaryData = rest.copyOfRange(2 + jsonLen, rest.size)
                    deliverStreamData(streamId, channel, totalChunks > 1, totalChunks, chunkIndex, binaryData)
                }
            }
            WorkletToNative.STATUS_RESPONSE -> {
                val json = parseJsonPayload(rest) ?: return
                @Suppress("UNCHECKED_CAST")
                onStatusResponse?.invoke(StatusEvent(
                    isHosting = json["isHosting"] as? Boolean ?: false,
                    isConnected = json["isConnected"] as? Boolean ?: false,
                    connectionCode = json["connectionCode"] as? String,
                    publicKeyHex = json["publicKeyHex"] as? String,
                    peers = json["peers"] as? List<Map<String, Any>> ?: emptyList()
                ))
            }
            WorkletToNative.ERROR -> {
                val json = parseJsonPayload(rest) ?: return
                val msg = json["message"] as? String ?: "Unknown error"
                Log.e(TAG, "Worklet error: $msg")
                onError?.invoke(msg)
            }
            WorkletToNative.LOG -> {
                val json = parseJsonPayload(rest) ?: return
                val msg = json["message"] as? String ?: ""
                Log.d(TAG, "Worklet: $msg")
                onLog?.invoke(msg)
            }
            WorkletToNative.LOOKUP_RESULT -> {
                val json = parseJsonPayload(rest) ?: return
                val code = json["code"] as? String ?: ""
                val online = json["online"] as? Boolean ?: false
                onLookupResult?.invoke(code, online)
            }
            WorkletToNative.DHT_NODES -> {
                val json = parseJsonPayload(rest) ?: return
                @Suppress("UNCHECKED_CAST")
                val nodes = json["nodes"] as? List<Map<String, Any>> ?: return
                onDhtNodes?.invoke(nodes)
            }
            WorkletToNative.CONNECTION_STATE -> {
                val json = try { org.json.JSONObject(String(rest, Charsets.UTF_8)) } catch (_: Exception) { return }
                val detail = json.optString("detail", "")
                onConnectionState?.invoke(detail)
            }

            WorkletToNative.OTA_UPDATE_AVAILABLE -> {
                // Frame format: [jsonLen: 2B BE] [JSON bytes] [binary bundle data]
                if (rest.size < 2) return
                val jsonLen = ((rest[0].toInt() and 0xFF) shl 8) or (rest[1].toInt() and 0xFF)
                if (rest.size < 2 + jsonLen) return
                val jsonStr = String(rest, 2, jsonLen, Charsets.UTF_8)
                val json = try { org.json.JSONObject(jsonStr) } catch (e: Exception) { return }
                val version = json.optString("version", "unknown")
                val bundleData = rest.copyOfRange(2 + jsonLen, rest.size)
                if (bundleData.isNotEmpty()) {
                    onOtaUpdate?.invoke(version, bundleData)
                }
            }
        }
    }

    private fun deliverStreamData(
        streamId: Int, channel: Byte, isChunked: Boolean,
        totalChunks: Int, chunkIndex: Int, binaryData: ByteArray
    ) {
        val ch = channel.toInt() and 0xFF

        // Channel 0 time gate
        if (ch == 0) {
            val isChunk0 = isChunked && chunkIndex == 0
            if (!isChunked || isChunk0) {
                val now = System.nanoTime()
                if (now - lastCh0AcceptTime < ch0MinIntervalNs) {
                    ch0DropCount++
                    lastCh0FrameAccepted = false
                    return
                }
                lastCh0AcceptTime = now
                lastCh0FrameAccepted = true
            } else if (isChunked && !lastCh0FrameAccepted) {
                ch0DropCount++
                return
            }
        }

        if (isChunked) {
            val key = "$streamId:$ch"
            if (chunkBuffers.size > MAX_PENDING_CHUNK_BUFFERS / 2) {
                val expired = chunkBuffers.entries.filter { it.value.isExpired() }
                expired.forEach { chunkBuffers.remove(it.key) }
            }
            if (chunkIndex == 0 && totalChunks <= MAX_CHUNKS_PER_BUFFER
                && chunkBuffers.size < MAX_PENDING_CHUNK_BUFFERS) {
                chunkBuffers[key] = ChunkBuffer(totalChunks)
            }
            val buf = chunkBuffers[key]
            if (buf == null || chunkIndex >= buf.total) {
                orphanedChunkCount++
                return
            }
            buf.add(chunkIndex, binaryData)
            if (buf.isComplete) {
                chunkAssembledCount++
                val assembled = buf.assemble()
                chunkBuffers.remove(key)
                if (ch == 0) pendingVideoData.add(assembled)
                onStreamData?.invoke(StreamDataEvent(streamId, ch.toByte(), assembled))
            }
        } else {
            if (ch == 0) pendingVideoData.add(binaryData)
            onStreamData?.invoke(StreamDataEvent(streamId, ch.toByte(), binaryData))
        }
    }

    // MARK: - JSON helpers

    private fun parseJsonPayload(data: ByteArray): Map<String, Any>? {
        if (data.isEmpty()) return null
        return jsonDecode(String(data, Charsets.UTF_8))
    }

    private fun jsonEncode(map: Map<String, Any>): String {
        val sb = StringBuilder("{")
        var first = true
        for ((key, value) in map) {
            if (!first) sb.append(",")
            first = false
            sb.append("\"").append(escapeJson(key)).append("\":")
            appendJsonValue(sb, value)
        }
        sb.append("}")
        return sb.toString()
    }

    private fun appendJsonValue(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is String -> sb.append("\"").append(escapeJson(value)).append("\"")
            is Number -> sb.append(value)
            is Boolean -> sb.append(value)
            is Map<*, *> -> {
                sb.append("{")
                var first = true
                for ((k, v) in value) {
                    if (!first) sb.append(",")
                    first = false
                    sb.append("\"").append(escapeJson(k.toString())).append("\":")
                    appendJsonValue(sb, v)
                }
                sb.append("}")
            }
            is List<*> -> {
                sb.append("[")
                var first = true
                for (item in value) {
                    if (!first) sb.append(",")
                    first = false
                    appendJsonValue(sb, item)
                }
                sb.append("]")
            }
            else -> sb.append("\"").append(escapeJson(value.toString())).append("\"")
        }
    }

    private fun escapeJson(s: String): String {
        return s.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    }

    @Suppress("UNCHECKED_CAST")
    private fun jsonDecode(s: String): Map<String, Any>? {
        return try {
            org.json.JSONObject(s).let { obj ->
                val map = HashMap<String, Any>()
                for (key in obj.keys()) {
                    map[key] = jsonObjectToKotlin(obj.get(key))
                }
                map
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun jsonObjectToKotlin(value: Any): Any {
        return when (value) {
            is org.json.JSONObject -> {
                val map = HashMap<String, Any>()
                for (key in value.keys()) {
                    map[key] = jsonObjectToKotlin(value.get(key))
                }
                map
            }
            is org.json.JSONArray -> {
                val list = ArrayList<Any>()
                for (i in 0 until value.length()) {
                    list.add(jsonObjectToKotlin(value.get(i)))
                }
                list
            }
            else -> value
        }
    }

    // MARK: - Chunk buffer

    private class ChunkBuffer(val total: Int) {
        private val createdAt = System.currentTimeMillis()
        private val chunks = HashMap<Int, ByteArray>()
        val isComplete: Boolean get() = chunks.size == total

        fun add(index: Int, data: ByteArray) {
            if (index < total) chunks[index] = data
        }

        fun isExpired(): Boolean = System.currentTimeMillis() - createdAt > 2000

        fun assemble(): ByteArray {
            var totalSize = 0
            for (i in 0 until total) {
                totalSize += chunks[i]?.size ?: 0
            }
            val result = ByteArray(totalSize)
            var offset = 0
            for (i in 0 until total) {
                val chunk = chunks[i] ?: continue
                System.arraycopy(chunk, 0, result, offset, chunk.size)
                offset += chunk.size
            }
            return result
        }
    }

    companion object {
        private const val TAG = "BareWorkletBridge"
        private const val MAX_CHUNK_PAYLOAD = 16_000
        private const val MAX_PENDING_WRITE_BYTES = 1_000_000
        private const val MAX_FRAME_LENGTH = 5 * 1024 * 1024
        private const val MAX_CHUNKS_PER_BUFFER = 256
        private const val MAX_PENDING_CHUNK_BUFFERS = 16
    }
}

// MARK: - Event types

data class HostingStartedEvent(val publicKeyHex: String, val connectionCode: String)
data class ConnectionEstablishedEvent(val peerKeyHex: String, val streamId: Int)
data class ConnectionFailedEvent(val code: String, val reason: String)
data class PeerConnectedEvent(val peerKeyHex: String, val peerName: String, val streamId: Int)
data class PeerDisconnectedEvent(val peerKeyHex: String, val reason: String)
data class StreamDataEvent(val streamId: Int, val channel: Byte, val data: ByteArray)
data class StatusEvent(
    val isHosting: Boolean,
    val isConnected: Boolean,
    val connectionCode: String?,
    val publicKeyHex: String?,
    val peers: List<Map<String, Any>>
)
