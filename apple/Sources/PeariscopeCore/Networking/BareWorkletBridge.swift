import Foundation
import BareKit

/// Message types sent from native to the JS worklet.
private enum NativeToWorklet: UInt8 {
    case startHosting = 0x01
    case stopHosting = 0x02
    case connectToPeer = 0x03
    case disconnect = 0x04
    case streamData = 0x05
    case statusRequest = 0x06
    case lookupPeer = 0x07
}

/// Message types received from the JS worklet.
private enum WorkletToNative: UInt8 {
    case hostingStarted = 0x81
    case hostingStopped = 0x82
    case connectionEstablished = 0x83
    case connectionFailed = 0x84
    case peerConnected = 0x85
    case peerDisconnected = 0x86
    case streamData = 0x87
    case statusResponse = 0x88
    case error = 0x89
    case log = 0x8A
    case lookupResult = 0x8B
}

/// Events emitted by BareWorkletBridge.
public struct BareHostingStartedEvent {
    public let publicKeyHex: String
    public let connectionCode: String
}

public struct BareConnectionEstablishedEvent {
    public let peerKeyHex: String
    public let streamId: UInt32
}

public struct BareConnectionFailedEvent {
    public let code: String
    public let reason: String
}

public struct BarePeerConnectedEvent {
    public let peerKeyHex: String
    public let peerName: String
    public let streamId: UInt32
}

public struct BarePeerDisconnectedEvent {
    public let peerKeyHex: String
    public let reason: String
}

public struct BareStreamDataEvent {
    public let streamId: UInt32
    public let channel: UInt8
    public let data: Data
}

public struct BareStatusEvent {
    public let isHosting: Bool
    public let isConnected: Bool
    public let peers: [[String: Any]]
}

/// Bridge between Swift and the Pear runtime (Bare + Hyperswarm) running in a BareWorklet.
public final class BareWorkletBridge: @unchecked Sendable {
    private var worklet: BareWorklet?
    private var ipc: BareIPC?
    private let queue = DispatchQueue(label: "peariscope.bare", qos: .userInteractive)


    private var recvBuf = Data()
    private var recvBufOffset = 0
    private var drainCount = 0
    private var ipcReadCount = 0
    private var streamDataRecvCount = 0
    private var chunkBuffers: [String: ChunkBuffer] = [:]
    private var chunkAssembledCount = 0
    private var chunkReplacedCount = 0
    private var unchunkedCount = 0
    /// Count of ch0 frames that entered the chunked path but had no buffer (orphaned chunks)
    private var orphanedChunkCount = 0
    /// Count of ch0 frames that had isChunked=true (for diagnosing unexpected chunking)
    private var ch0ChunkedCount = 0
    /// Bytes received on ch0 per second (for diagnosing throughput)
    private var ch0BytesThisInterval = 0
    private var ch0BytesLastLog: CFAbsoluteTime = 0

    /// Per-channel stream data counters for diagnostics.
    /// Helps identify StreamMux framing corruption (phantom frames on ch1/ch2).
    private var ch0RecvCount = 0
    private var ch1RecvCount = 0
    private var ch2RecvCount = 0
    private var chOtherRecvCount = 0

    /// Channel 0 time gate — defense-in-depth against JS-side rate limiting failures.
    /// Skips Data allocation + onStreamData callback for gated ch0 frames.
    private var lastCh0AcceptTime: CFAbsoluteTime = 0
    private var ch0DropCount = 0
    private var lastCh0FrameAccepted = false  // tracks whether last chunk-0 passed gate
    private static let ch0MinInterval: CFTimeInterval = 1.0 / 61.0

    /// Lock protecting recvBuf, recvBufOffset, chunkBuffers, and all state
    /// accessed in the readable callback and drainFrames/handleFrame.
    /// BareKit fires readable callbacks from a thread pool — without this lock,
    /// concurrent access corrupts recvBuf and breaks chunk assembly.
    private let recvLock = NSLock()

    // Diagnostics: track IPC data volume per second
    private var ipcBytesThisInterval: Int = 0
    private var ipcFramesThisInterval: Int = 0
    private var lastIpcDiagTime: CFAbsoluteTime = 0

    /// Write buffer for handling partial IPC writes.
    /// BareIPC.write() can return fewer bytes than requested when the pipe buffer is full.
    /// Without buffering, this corrupts the length-prefixed framing.
    private var pendingWrite = Data()
    private var droppedFrameCount = 0
    /// Maximum pending write buffer (bytes) before dropping video frames.
    /// Must be large enough for chunked keyframes (100-500KB at high resolutions).
    /// 2MB matches the JS-side IPC write buffer limit.
    private static let maxPendingWriteBytes = 2_000_000

    /// Maximum chunks per buffer and max pending buffers
    private static let maxChunksPerBuffer = 256
    private static let maxPendingChunkBuffers = 16

    private struct ChunkBuffer {
        let total: Int
        let createdAt: CFAbsoluteTime
        var chunks: [Int: Data] = [:]
        var isComplete: Bool { chunks.count == total }

        init(total: Int) {
            self.total = min(total, BareWorkletBridge.maxChunksPerBuffer)
            self.createdAt = CFAbsoluteTimeGetCurrent()
        }

        mutating func add(index: Int, data: Data) {
            chunks[index] = data
        }

        var isExpired: Bool {
            CFAbsoluteTimeGetCurrent() - createdAt > 2.0
        }

        func assemble() -> Data {
            var result = Data()
            for i in 0..<total {
                if let chunk = chunks[i] {
                    result.append(chunk)
                }
            }
            return result
        }
    }

    public var onHostingStarted: ((BareHostingStartedEvent) -> Void)?
    public var onHostingStopped: (() -> Void)?
    public var onConnectionEstablished: ((BareConnectionEstablishedEvent) -> Void)?
    public var onConnectionFailed: ((BareConnectionFailedEvent) -> Void)?
    public var onPeerConnected: ((BarePeerConnectedEvent) -> Void)?
    public var onPeerDisconnected: ((BarePeerDisconnectedEvent) -> Void)?
    public var onStreamData: ((BareStreamDataEvent) -> Void)?
    public var onStatusResponse: ((BareStatusEvent) -> Void)?
    public var onError: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onLookupResult: ((String, Bool) -> Void)?  // (code, online)

    public init() {}

    /// Start the Bare worklet with the packed Pear networking bundle.
    /// - Parameter assetsPath: Path to directory containing worklet.bundle
    public func start(assetsPath: String) throws {
        let config = BareWorkletConfiguration.default()!

        // Assets must point to Frameworks directory so BareKit can resolve linked native addons
        #if os(macOS)
        let frameworksPath = Bundle.main.bundlePath + "/Contents/Frameworks"
        #else
        let frameworksPath = Bundle.main.bundlePath + "/Frameworks"
        #endif
        config.assets = frameworksPath

        let w = BareWorklet(configuration: config)!
        worklet = w

        // IMPORTANT: Start worklet BEFORE creating IPC
        // BareKit IPC pipe fds are only valid after start() returns
        let bundlePath = (assetsPath as NSString).appendingPathComponent("worklet.bundle")
        guard let bundleData = FileManager.default.contents(atPath: bundlePath) else {
            print("[bare] ERROR: worklet.bundle not found at \(bundlePath)")
            return
        }

        // Load bundle as UTF-8 string and use start:source:encoding: with .bundle filename
        guard let bundleStr = String(data: bundleData, encoding: .utf8) else {
            print("[bare] ERROR: worklet.bundle is not valid UTF-8")
            return
        }
        w.start("/worklet.bundle", source: bundleStr, encoding: String.Encoding.utf8.rawValue, arguments: nil)
        print("[bare] Worklet started (\(bundleData.count) bytes)")

        // Create IPC AFTER start - pipe fds are only valid after worklet starts
        let bareIpc = BareIPC(worklet: w)!
        ipc = bareIpc

        // Read IPC data directly in the callback thread.
        // Wrap in autoreleasepool — this callback runs on BareKit's internal thread
        // which has no automatic autorelease pool drain, so Foundation objects
        // (from JSONSerialization, NSLog, etc.) accumulate until process exit.
        bareIpc.readable = { [weak self] ipc in
            guard let self else { return }
            // BareKit fires readable callbacks from a thread pool. Without this lock,
            // concurrent access to recvBuf/chunkBuffers corrupts data and breaks
            // chunk assembly — only 1 frame ever completes despite 165K+ IPC messages.
            self.recvLock.lock()
            defer { self.recvLock.unlock() }

            // Limit reads per callback to prevent:
            // 1. Autoreleasepool accumulation (Foundation objects from JSON parsing)
            // 2. IPC pipe never backing up (JS never sees backpressure)
            // By reading only a small batch, the IPC pipe fills up, JS ipcPipe.write()
            // returns false, JS buffers data, and when JS buffer exceeds threshold,
            // video frames are dropped and Hyperswarm stream is paused.
            #if os(iOS)
            let maxReadsPerCallback = 50
            #else
            let maxReadsPerCallback = 500
            #endif
            var readsThisBatch = 0
            while readsThisBatch < maxReadsPerCallback, let data = ipc.read() {
                autoreleasepool {
                    readsThisBatch += 1
                    self.ipcReadCount += 1
                    self.ipcBytesThisInterval += data.count
                    self.ipcFramesThisInterval += 1

                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.lastIpcDiagTime >= 1.0 {
                        #if os(iOS)
                        let availMB = os_proc_available_memory() / 1_048_576
                        NSLog("[ipc-diag] throughput: %d bytes, %d frames in %.1fs, recvBuf=%d, pendingWrite=%d, mem=%dMB",
                              self.ipcBytesThisInterval, self.ipcFramesThisInterval,
                              now - self.lastIpcDiagTime, self.recvBuf.count - self.recvBufOffset,
                              self.pendingWrite.count, availMB)
                        #else
                        NSLog("[ipc-diag] throughput: %d bytes, %d frames in %.1fs, recvBuf=%d, pendingWrite=%d",
                              self.ipcBytesThisInterval, self.ipcFramesThisInterval,
                              now - self.lastIpcDiagTime, self.recvBuf.count - self.recvBufOffset,
                              self.pendingWrite.count)
                        #endif
                        self.ipcBytesThisInterval = 0
                        self.ipcFramesThisInterval = 0
                        self.lastIpcDiagTime = now
                    }

                    if self.ipcReadCount <= 10 || self.ipcReadCount % 500 == 0 {
                        #if os(iOS)
                        let availMB = os_proc_available_memory() / 1_048_576
                        NSLog("[bare-ipc] read %d bytes, recvBuf=%d, readCount=%d, mem=%dMB", data.count, self.recvBuf.count, self.ipcReadCount, availMB)
                        #else
                        NSLog("[bare-ipc] read %d bytes, recvBuf=%d, readCount=%d", data.count, self.recvBuf.count, self.ipcReadCount)
                        #endif
                    }
                    #if os(iOS)
                    if self.ipcReadCount % 100 == 0 {
                        let availMB = os_proc_available_memory() / 1_048_576
                        if availMB > 0 && availMB < 200 {
                            NSLog("[bare-ipc] LOW MEMORY %dMB — dropping IPC data", availMB)
                            self.recvBuf.removeAll()
                            self.recvBufOffset = 0
                            return
                        }
                    }
                    #endif
                    let bufSize = self.recvBuf.count - self.recvBufOffset
                    if bufSize > 2_000_000 {
                        self.recvBuf.removeAll()
                        self.recvBufOffset = 0
                        NSLog("[bare-ipc] recvBuf overflow (%d bytes), dropped", bufSize + data.count)
                        return
                    }
                    self.recvBuf.append(data)
                    self.drainFrames()
                }
            }
        }

        // Resume flushing pending writes when the pipe is ready for more data
        bareIpc.writable = { [weak self] _ in
            guard let self else { return }
            self.writeQueue.async { [weak self] in
                guard let self, let ipc = self.ipc else { return }
                self.flushPendingWrites(ipc)
            }
        }
    }

    // MARK: - Commands (native -> worklet)

    public func startHosting(deviceCode: String? = nil) {
        if let deviceCode {
            sendCommand(.startHosting, json: ["deviceCode": deviceCode])
        } else {
            sendCommand(.startHosting)
        }
    }

    public func stopHosting() {
        sendCommand(.stopHosting)
    }

    public func connectToPeer(code: String) {
        sendCommand(.connectToPeer, json: ["code": code])
    }

    public func disconnect(peerKeyHex: String) {
        sendCommand(.disconnect, json: ["peerKeyHex": peerKeyHex])
    }

    /// Maximum payload size per IPC chunk. Must be well under the pipe buffer (64KB on macOS).
    /// Each chunk becomes a separate IPC frame: 4B length + 1B type + payload.
    private static let maxChunkPayload = 16_000

    public func sendStreamData(streamId: UInt32, channel: UInt8, data: Data) {
        // For small frames, send directly (no chunking overhead)
        if data.count <= Self.maxChunkPayload {
            var payload = Data(capacity: 7 + data.count)
            var sid = streamId.bigEndian
            payload.append(Data(bytes: &sid, count: 4))
            payload.append(channel)
            // chunkInfo: totalChunks=1 (0 means single/unchunked), chunkIndex=0
            payload.append(0) // totalChunks high byte (0 = no chunking)
            payload.append(0) // totalChunks low byte
            payload.append(data)
            sendCommand(.streamData, binary: payload)
            return
        }

        // Split large data into chunks
        let totalChunks = (data.count + Self.maxChunkPayload - 1) / Self.maxChunkPayload
        for i in 0..<totalChunks {
            let offset = i * Self.maxChunkPayload
            let end = min(offset + Self.maxChunkPayload, data.count)
            let chunk = data[offset..<end]

            var payload = Data(capacity: 9 + chunk.count)
            var sid = streamId.bigEndian
            payload.append(Data(bytes: &sid, count: 4))
            payload.append(channel)
            // Chunk header: totalChunks (UInt16 BE), chunkIndex (UInt16 BE)
            var tc = UInt16(totalChunks).bigEndian
            payload.append(Data(bytes: &tc, count: 2))
            var ci = UInt16(i).bigEndian
            payload.append(Data(bytes: &ci, count: 2))
            payload.append(chunk)
            sendCommand(.streamData, binary: payload)
        }
    }

    public func requestStatus() {
        sendCommand(.statusRequest)
    }

    public func lookupPeer(code: String) {
        sendCommand(.lookupPeer, json: ["code": code])
    }

    /// Whether the worklet is alive and has an IPC pipe.
    public var isAlive: Bool { worklet != nil && ipc != nil }

    /// Diagnostic summary for heartbeat logging.
    public func diagnosticSummary() -> String {
        return "ipcReads=\(ipcReadCount) streamDataRecv=\(streamDataRecvCount) ch=\(ch0RecvCount)/\(ch1RecvCount)/\(ch2RecvCount)/\(chOtherRecvCount) recvBuf=\(recvBuf.count - recvBufOffset) pendingWrite=\(pendingWrite.count) chunkBufs=\(chunkBuffers.count) assembled=\(chunkAssembledCount) replaced=\(chunkReplacedCount) unchunked=\(unchunkedCount) orphaned=\(orphanedChunkCount) ch0chunked=\(ch0ChunkedCount) dropped=\(droppedFrameCount) ch0gate=\(ch0DropCount)"
    }

    public func terminate() {
        writeQueue.sync {
            pendingWrite.removeAll()
        }
        worklet?.terminate()
        ipc?.close()
        worklet = nil
        ipc = nil
    }

    public func suspend() {
        worklet?.suspend()
    }

    public func resume() {
        worklet?.resume()
    }

    // MARK: - Frame encoding/decoding

    private var sendCmdCount = 0
    /// Serial queue for IPC writes to prevent interleaving/partial writes
    private let writeQueue = DispatchQueue(label: "peariscope.ipc.write", qos: .userInteractive)

    private func sendCommand(_ type: NativeToWorklet, json: [String: Any]? = nil, binary: Data? = nil) {
        guard let ipc else { return }

        var payload = Data()
        payload.append(type.rawValue)

        if let binary {
            payload.append(binary)
        } else if let json {
            if let jsonData = try? JSONSerialization.data(withJSONObject: json) {
                payload.append(jsonData)
            }
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)

        writeQueue.sync {
            // Backpressure: drop video frames when the write buffer is too full
            if type == .streamData && pendingWrite.count > Self.maxPendingWriteBytes {
                droppedFrameCount += 1
                if droppedFrameCount <= 10 || droppedFrameCount % 100 == 0 {
                    NSLog("[ipc-write] backpressure: dropping frame, pending=%d dropped=%d", pendingWrite.count, droppedFrameCount)
                }
                return
            }

            sendCmdCount += 1
            if sendCmdCount <= 10 || sendCmdCount % 500 == 0 || type != .streamData {
                NSLog("[ipc-send] type=0x%02x frameLen=%d sendCount=%d pending=%d", type.rawValue, frame.count, sendCmdCount, pendingWrite.count)
            }

            pendingWrite.append(frame)
            flushPendingWrites(ipc)
        }
    }

    /// Flush buffered data to the IPC pipe, handling partial writes.
    /// Must be called from writeQueue.
    private func flushPendingWrites(_ ipc: BareIPC) {
        while !pendingWrite.isEmpty {
            let written = ipc.write(pendingWrite)
            if written <= 0 {
                // Pipe buffer full or error — the writable callback will resume
                break
            }
            if written >= pendingWrite.count {
                pendingWrite.removeAll(keepingCapacity: true)
            } else {
                pendingWrite.removeFirst(Int(written))
            }
        }
    }

    /// Maximum allowed frame size (5MB) to prevent memory exhaustion from malicious peers
    private static let maxFrameLength = 5 * 1024 * 1024

    private func drainFrames() {
        while recvBuf.count - recvBufOffset >= 4 {
            let length = recvBuf.withUnsafeBytes { buf -> Int in
                Int(buf.loadUnaligned(fromByteOffset: recvBufOffset, as: UInt32.self).bigEndian)
            }
            if length > Self.maxFrameLength {
                NSLog("[bare-ipc] ERROR: frame length %d exceeds max %d, dropping buffer", length, Self.maxFrameLength)
                recvBuf.removeAll()
                recvBufOffset = 0
                return
            }
            guard recvBuf.count - recvBufOffset >= 4 + length else {
                drainCount += 1
                if drainCount <= 10 || drainCount % 500 == 0 {
                    NSLog("[bare-ipc] drain: waiting need=%d have=%d drainCount=%d", 4 + length, recvBuf.count - recvBufOffset, drainCount)
                }
                break
            }
            let frameStart = recvBufOffset + 4
            drainCount += 1

            // Hot path: streamData (0x87) messages are ~99% of traffic.
            // Handle them in-place from recvBuf to avoid two ~16KB subdata copies
            // per message (frame + rest). At 43K messages/sec during burst delivery,
            // these copies consumed ~1.4GB/sec of transient Data allocations.
            let frameType = recvBuf[frameStart]
            if frameType == WorkletToNative.streamData.rawValue {
                if drainCount <= 10 || drainCount % 500 == 0 {
                    NSLog("[bare-ipc] drain: frame len=%d type=0x%02x drainCount=%d", length, UInt32(frameType), drainCount)
                }
                handleStreamDataInPlace(at: frameStart, length: length)
            } else {
                let frame = recvBuf.subdata(in: frameStart..<(frameStart + length))
                if drainCount <= 10 || drainCount % 500 == 0 {
                    NSLog("[bare-ipc] drain: frame len=%d type=0x%02x drainCount=%d", length, frame.count >= 1 ? UInt32(frame[0]) : 0, drainCount)
                }
                handleFrame(frame)
            }
            recvBufOffset += 4 + length
        }
        // Compact buffer when we've consumed a significant portion
        if recvBufOffset > 65536 {
            recvBuf.removeSubrange(0..<recvBufOffset)
            recvBufOffset = 0
        }
    }

    /// Handle streamData messages in-place from recvBuf, avoiding two ~16KB subdata copies
    /// (frame + rest) per message. At 43K messages/sec this saves ~1.4GB/sec of allocations.
    /// Only the small JSON header (~80 bytes) and final binary payload are copied when needed.
    private func handleStreamDataInPlace(at offset: Int, length: Int) {
        streamDataRecvCount += 1
        // Need at least: type(1) + jsonLen(2) + 1 byte JSON
        guard length >= 4 else { return }

        let restOffset = offset + 1
        let restCount = length - 1
        let jsonLen = Int(recvBuf.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: restOffset, as: UInt16.self).bigEndian
        })
        guard restCount >= 2 + jsonLen else { return }

        // Small JSON copy (~80 bytes) — unavoidable for JSONSerialization
        let jsonData = recvBuf.subdata(in: (restOffset + 2)..<(restOffset + 2 + jsonLen))
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        let streamId = UInt32(json["streamId"] as? Int ?? 0)
        let channel = UInt8(json["channel"] as? Int ?? 0)
        let isChunked = (json["_totalChunks"] as? Int ?? 0) > 1

        // Per-channel counting — helps diagnose StreamMux framing corruption
        switch channel {
        case 0: ch0RecvCount += 1
        case 1: ch1RecvCount += 1
        case 2: ch2RecvCount += 1
        default: chOtherRecvCount += 1
        }

        // Track ch0 chunked frames for diagnostics
        if channel == 0 && isChunked {
            ch0ChunkedCount += 1
            if ch0ChunkedCount <= 5 {
                NSLog("[bare-ipc] ch0 CHUNKED frame: totalChunks=%d chunkIndex=%d isChunked=%d count=%d",
                      json["_totalChunks"] as? Int ?? -1, json["_chunkIndex"] as? Int ?? -1,
                      isChunked ? 1 : 0, ch0ChunkedCount)
            }
        }

        // Channel 0 time gate — gates chunk-0/unchunked by time, and non-zero chunks
        // based on whether their chunk-0 was accepted. Previously non-zero chunks passed
        // freely, causing 143K+ orphaned chunk processings (JSON parse + dictionary
        // lookup each) per second when chunk-0s were gated.
        if channel == 0 {
            let isChunk0 = isChunked && (json["_chunkIndex"] as? Int ?? -1) == 0
            if !isChunked || isChunk0 {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastCh0AcceptTime < Self.ch0MinInterval {
                    ch0DropCount += 1
                    lastCh0FrameAccepted = false
                    return
                }
                lastCh0AcceptTime = now
                lastCh0FrameAccepted = true
            } else if isChunked && !lastCh0FrameAccepted {
                // Non-zero chunk of a rejected frame — skip entirely
                ch0DropCount += 1
                return
            }
        }

        // Track ch0 binary data volume
        if channel == 0 {
            let binLen = (offset + length) - (restOffset + 2 + jsonLen)
            ch0BytesThisInterval += max(0, binLen)
            let now = CFAbsoluteTimeGetCurrent()
            if now - ch0BytesLastLog >= 1.0 {
                NSLog("[bare-ipc] ch0 throughput: %d bytes/sec, chunked=%d unchunked=%d gated=%d orphaned=%d",
                      ch0BytesThisInterval, ch0ChunkedCount, unchunkedCount, ch0DropCount, orphanedChunkCount)
                ch0BytesThisInterval = 0
                ch0BytesLastLog = now
            }
        }

        let binaryStart = restOffset + 2 + jsonLen
        let binaryEnd = offset + length

        if isChunked,
           let totalChunks = json["_totalChunks"] as? Int,
           let chunkIndex = json["_chunkIndex"] as? Int {
            let key = "\(streamId):\(channel)"
            if chunkBuffers.count > Self.maxPendingChunkBuffers / 2 {
                chunkBuffers = chunkBuffers.filter { !$0.value.isExpired }
            }
            if chunkIndex == 0 && totalChunks <= Self.maxChunksPerBuffer
                && chunkBuffers.count < Self.maxPendingChunkBuffers {
                if let existing = chunkBuffers[key], !existing.isComplete {
                    chunkReplacedCount += 1
                }
                chunkBuffers[key] = ChunkBuffer(total: totalChunks)
            }
            guard var buf = chunkBuffers[key], chunkIndex < buf.total else {
                orphanedChunkCount += 1
                return
            }
            // Only allocate binaryData after confirming the chunk has a live buffer
            let binaryData = recvBuf.subdata(in: binaryStart..<binaryEnd)
            if streamDataRecvCount <= 5 || streamDataRecvCount % 300 == 0 {
                NSLog("[bare-ipc] streamData ch=%d sid=%d binLen=%d count=%d ch0drop=%d", channel, streamId, binaryData.count, streamDataRecvCount, ch0DropCount)
            }
            buf.add(index: chunkIndex, data: binaryData)
            chunkBuffers[key] = buf
            if buf.isComplete {
                chunkAssembledCount += 1
                let assembled = buf.assemble()
                chunkBuffers.removeValue(forKey: key)
                let event = BareStreamDataEvent(
                    streamId: streamId,
                    channel: channel,
                    data: assembled
                )
                onStreamData?(event)
            }
        } else {
            let binaryData = recvBuf.subdata(in: binaryStart..<binaryEnd)
            if streamDataRecvCount <= 5 || streamDataRecvCount % 300 == 0 {
                NSLog("[bare-ipc] streamData ch=%d sid=%d binLen=%d count=%d ch0drop=%d", channel, streamId, binaryData.count, streamDataRecvCount, ch0DropCount)
            }
            unchunkedCount += 1
            let event = BareStreamDataEvent(
                streamId: streamId,
                channel: channel,
                data: binaryData
            )
            onStreamData?(event)
        }
    }

    private func handleFrame(_ frame: Data) {
        guard frame.count >= 1 else { return }
        let type = frame[0]
        let rest = frame.subdata(in: 1..<frame.count)

        guard let msgType = WorkletToNative(rawValue: type) else {
            print("[bare] Unknown message type: 0x\(String(type, radix: 16))")
            return
        }

        switch msgType {
        case .hostingStarted:
            if let json = parseJSON(rest) {
                let event = BareHostingStartedEvent(
                    publicKeyHex: json["publicKeyHex"] as? String ?? "",
                    connectionCode: json["connectionCode"] as? String ?? ""
                )
                onHostingStarted?(event)
            }

        case .hostingStopped:
            onHostingStopped?()

        case .connectionEstablished:
            if let json = parseJSON(rest) {
                let event = BareConnectionEstablishedEvent(
                    peerKeyHex: json["peerKeyHex"] as? String ?? "",
                    streamId: UInt32(json["streamId"] as? Int ?? 0)
                )
                onConnectionEstablished?(event)
            }

        case .connectionFailed:
            if let json = parseJSON(rest) {
                let event = BareConnectionFailedEvent(
                    code: json["code"] as? String ?? "",
                    reason: json["reason"] as? String ?? ""
                )
                onConnectionFailed?(event)
            }

        case .peerConnected:
            if let json = parseJSON(rest) {
                let event = BarePeerConnectedEvent(
                    peerKeyHex: json["peerKeyHex"] as? String ?? "",
                    peerName: json["peerName"] as? String ?? "",
                    streamId: UInt32(json["streamId"] as? Int ?? 0)
                )
                onPeerConnected?(event)
            }

        case .peerDisconnected:
            if let json = parseJSON(rest) {
                let event = BarePeerDisconnectedEvent(
                    peerKeyHex: json["peerKeyHex"] as? String ?? "",
                    reason: json["reason"] as? String ?? ""
                )
                onPeerDisconnected?(event)
            }

        case .streamData:
            streamDataRecvCount += 1
            if rest.count >= 3 {
                let jsonLen = Int(rest.withUnsafeBytes { ptr -> UInt16 in
                    ptr.load(as: UInt16.self).bigEndian
                })
                guard rest.count >= 2 + jsonLen else { break }
                let jsonData = rest.subdata(in: 2..<(2 + jsonLen))

                if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    let streamId = UInt32(json["streamId"] as? Int ?? 0)
                    let channel = UInt8(json["channel"] as? Int ?? 0)

                    let isChunked = (json["_totalChunks"] as? Int ?? 0) > 1

                    // Channel 0 time gate — skip Data allocation entirely for gated frames.
                    // This is defense-in-depth: even if the JS-side rate limiter fails and
                    // floods IPC with 30K+ fps, Swift only processes ~60fps of video data.
                    // We check BEFORE allocating binaryData to avoid the copy.
                    // Gate applies to BOTH unchunked AND chunk 0 (which starts a new
                    // ChunkBuffer). Non-zero chunks are gated by whether their buffer exists.
                    if channel == 0 {
                        let isChunk0 = isChunked && (json["_chunkIndex"] as? Int ?? -1) == 0
                        if !isChunked || isChunk0 {
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - lastCh0AcceptTime < Self.ch0MinInterval {
                                ch0DropCount += 1
                                break
                            }
                            lastCh0AcceptTime = now
                        }
                    }

                    // Check for chunked data — defer binaryData allocation until after
                    // guard check to avoid 16KB Data copies for orphaned chunks (37K/sec
                    // of wasted allocations when assembly is broken).
                    if isChunked,
                       let totalChunks = json["_totalChunks"] as? Int,
                       let chunkIndex = json["_chunkIndex"] as? Int {
                        let key = "\(streamId):\(channel)"
                        // Evict expired chunk buffers (>2s old = never completing)
                        if chunkBuffers.count > Self.maxPendingChunkBuffers / 2 {
                            chunkBuffers = chunkBuffers.filter { !$0.value.isExpired }
                        }
                        if chunkIndex == 0 && totalChunks <= Self.maxChunksPerBuffer
                            && chunkBuffers.count < Self.maxPendingChunkBuffers {
                            // Track if we're replacing an incomplete buffer
                            if let existing = chunkBuffers[key], !existing.isComplete {
                                chunkReplacedCount += 1
                            }
                            chunkBuffers[key] = ChunkBuffer(total: totalChunks)
                        }
                        // Skip orphaned chunks: if no buffer exists for this key
                        // (chunk 0 was dropped or buffer was evicted), skip entirely.
                        // No binaryData allocation = no wasted memory for dead chunks.
                        guard var buf = chunkBuffers[key], chunkIndex < buf.total else {
                            break
                        }
                        // Only allocate binaryData NOW — after confirming the chunk has
                        // a live buffer to go into. Previously this was allocated before
                        // the guard, wasting 16KB × 37K/sec = 592MB/sec for orphaned chunks.
                        let binaryData = rest.subdata(in: (2 + jsonLen)..<rest.count)
                        if streamDataRecvCount <= 5 || streamDataRecvCount % 300 == 0 {
                            NSLog("[bare-ipc] streamData ch=%d sid=%d binLen=%d count=%d ch0drop=%d", channel, streamId, binaryData.count, streamDataRecvCount, ch0DropCount)
                        }
                        buf.add(index: chunkIndex, data: binaryData)
                        chunkBuffers[key] = buf
                        if buf.isComplete {
                            chunkAssembledCount += 1
                            let assembled = buf.assemble()
                            chunkBuffers.removeValue(forKey: key)
                            let event = BareStreamDataEvent(
                                streamId: streamId,
                                channel: channel,
                                data: assembled
                            )
                            onStreamData?(event)
                        }
                    } else {
                        let binaryData = rest.subdata(in: (2 + jsonLen)..<rest.count)
                        if streamDataRecvCount <= 5 || streamDataRecvCount % 300 == 0 {
                            NSLog("[bare-ipc] streamData ch=%d sid=%d binLen=%d count=%d ch0drop=%d", channel, streamId, binaryData.count, streamDataRecvCount, ch0DropCount)
                        }
                        unchunkedCount += 1
                        let event = BareStreamDataEvent(
                            streamId: streamId,
                            channel: channel,
                            data: binaryData
                        )
                        onStreamData?(event)
                    }
                }
            }

        case .statusResponse:
            if let json = parseJSON(rest) {
                let event = BareStatusEvent(
                    isHosting: json["isHosting"] as? Bool ?? false,
                    isConnected: json["isConnected"] as? Bool ?? false,
                    peers: json["peers"] as? [[String: Any]] ?? []
                )
                onStatusResponse?(event)
            }

        case .error:
            if let json = parseJSON(rest) {
                let errMsg = json["message"] as? String ?? "Unknown error"
                print("[bare-js] ERROR: \(errMsg)")
                onError?(errMsg)
            }

        case .log:
            if let json = parseJSON(rest) {
                let msg = json["message"] as? String ?? ""
                NSLog("[bare-js] %@", msg)
                onLog?(msg)
            }

        case .lookupResult:
            if let json = parseJSON(rest) {
                let code = json["code"] as? String ?? ""
                let online = json["online"] as? Bool ?? false
                onLookupResult?(code, online)
            }
        }
    }

    private func parseJSON(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
