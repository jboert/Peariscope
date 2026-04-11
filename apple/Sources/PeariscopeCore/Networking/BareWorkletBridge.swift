import Foundation
import BareKit
import Security
import CryptoKit

/// Message types sent from native to the JS worklet.
private enum NativeToWorklet: UInt8 {
    case startHosting = 0x01
    case stopHosting = 0x02
    case connectToPeer = 0x03
    case disconnect = 0x04
    case streamData = 0x05
    case statusRequest = 0x06
    case lookupPeer = 0x07
    case cachedDhtNodes = 0x08
    case suspend = 0x09
    case resume = 0x0A
    case approvePeer = 0x0B
    case connectLocalPeer = 0x0C
    case reannounce = 0x0D
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
    case dhtNodes = 0x8C
    case otaUpdateAvailable = 0x8D
    case connectionStatus = 0x8E
}

/// Events emitted by BareWorkletBridge.
public struct BareHostingStartedEvent {
    public let publicKeyHex: String
    public let connectionCode: String
    public let dhtPort: UInt16
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
    public let connectionCode: String?
    public let publicKeyHex: String?
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
    public private(set) var ipcReadCount = 0
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

    /// Per-channel stream data counters for diagnostics.
    /// Helps identify StreamMux framing corruption (phantom frames on ch1/ch2).
    private var ch0RecvCount = 0
    private var ch1RecvCount = 0
    private var ch2RecvCount = 0
    private var chOtherRecvCount = 0

    /// Channel 0 time gate — defense-in-depth against JS-side rate limiting failures.
    /// Defense-in-depth rate limiter for channel 0 (video). The primary rate
    /// limiter is now centralized in StreamMux (JS worklet), but this Swift-side
    /// gate remains as a safety net in case the JS gate is bypassed or disabled.
    /// Skips Data allocation + onStreamData callback for gated ch0 frames.
    private var lastCh0AcceptTime: CFAbsoluteTime = 0
    private var ch0DropCount = 0
    private var lastCh0FrameAccepted = true  // true initially so first chunked frame's non-zero chunks pass
    private static let ch0MinInterval: CFTimeInterval = 1.0 / 61.0

    /// Lock protecting recvBuf, recvBufOffset, chunkBuffers, and all state
    /// accessed in the readable callback and drainFrames/handleFrame.
    /// BareKit fires readable callbacks from a thread pool — without this lock,
    /// concurrent access corrupts recvBuf and breaks chunk assembly.
    private let recvLock = NSLock()

    /// Video data collected during drainFrames to be delivered AFTER recvLock is released.
    /// Calling onCh0VideoData inside recvLock causes deadlock/crash — the callback
    /// (CrashLog.write, decoder dispatch) blocks or crashes, killing the IPC thread
    /// with recvLock held, permanently blocking all future IPC reads.
    private var pendingVideoData: [Data] = []

    // Diagnostics: track IPC data volume per second

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
    /// Direct ch0 video data callback — bypasses NetworkManager's @MainActor isolation.
    /// Called from BareKit IPC thread with raw video data. Set this from non-@MainActor
    /// context (e.g., with captured decoder references) to avoid Swift 6 actor hopping.
    public var onCh0VideoData: ((Data) -> Void)?
    public var onStatusResponse: ((BareStatusEvent) -> Void)?
    public var onError: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onLookupResult: ((String, Bool) -> Void)?  // (code, online)
    public var onDhtNodes: (([[String: Any]]) -> Void)?
    public var onOtaUpdate: ((String, Data) -> Void)?  // (version, bundleData)
    public var onConnectionStatus: ((String, String) -> Void)?  // (phase, detail)

    public init() {}

    /// Start the Bare worklet with the packed Pear networking bundle.
    /// - Parameter assetsPath: Path to directory containing worklet.bundle
    public func start(assetsPath: String) throws {
        guard let config = BareWorkletConfiguration.default() else {
            throw NSError(domain: "BareWorkletBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "BareWorkletConfiguration.default() returned nil"])
        }

        // Assets must point to Frameworks directory so BareKit can resolve linked native addons
        #if os(macOS)
        let frameworksPath = Bundle.main.bundlePath + "/Contents/Frameworks"
        #else
        let frameworksPath = Bundle.main.bundlePath + "/Frameworks"
        #endif
        config.assets = frameworksPath

        guard let w = BareWorklet(configuration: config) else {
            throw NSError(domain: "BareWorkletBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "BareWorklet(configuration:) returned nil"])
        }
        worklet = w

        // IMPORTANT: Start worklet BEFORE creating IPC
        // BareKit IPC pipe fds are only valid after start() returns
        let bundlePath = (assetsPath as NSString).appendingPathComponent("worklet.bundle")
        guard let bundleData = FileManager.default.contents(atPath: bundlePath) else {
            print("[bare] ERROR: worklet.bundle not found at \(bundlePath)")
            worklet = nil
            throw NSError(domain: "BareWorkletBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "worklet.bundle not found at \(bundlePath)"])
        }

        // Load bundle as UTF-8 string and use start:source:encoding: with .bundle filename
        guard let bundleStr = String(data: bundleData, encoding: .utf8) else {
            print("[bare] ERROR: worklet.bundle is not valid UTF-8")
            worklet = nil
            throw NSError(domain: "BareWorkletBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "worklet.bundle is not valid UTF-8"])
        }
        w.start("/worklet.bundle", source: bundleStr, encoding: String.Encoding.utf8.rawValue, arguments: nil)

        // Log bundle identity so rename-drift / stale bundles surface at runtime
        // instead of silently running old code. Size + SHA1 pins the exact content;
        // mtime pins which build produced it.
        let shortSha: String = {
            let digest = Insecure.SHA1.hash(data: bundleData)
            return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        }()
        let mtimeStr: String = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: bundlePath),
                  let date = attrs[.modificationDate] as? Date else { return "?" }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return fmt.string(from: date)
        }()
        NSLog("[bare] Worklet started (%d bytes, sha1=%@, mtime=%@)", bundleData.count, shortSha, mtimeStr)

        // Create IPC AFTER start - pipe fds are only valid after worklet starts
        guard let bareIpc = BareIPC(worklet: w) else {
            worklet = nil
            throw NSError(domain: "BareWorkletBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "BareIPC(worklet:) returned nil"])
        }
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
            // Process IPC reads under lock, collect video data to deliver after unlock.
            self.recvLock.lock()

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
                    #if os(iOS)
                    if self.ipcReadCount % 100 == 0 {
                        let availMB = os_proc_available_memory() / 1_048_576
                        if availMB > 0 && availMB < 200 {
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
                        return
                    }
                    self.recvBuf.append(data)
                    self.drainFrames()
                }
            }

            // Grab pending video data and release lock BEFORE firing callbacks.
            // Calling onCh0VideoData inside recvLock deadlocks — the callback does
            // CrashLog.write (synchronous fsync) and decoder dispatch that can block,
            // killing the thread with recvLock held and permanently blocking IPC.
            let videoToDeliver = self.pendingVideoData
            self.pendingVideoData.removeAll(keepingCapacity: true)
            let videoCb = self.onCh0VideoData
            self.recvLock.unlock()

            // Fire video callbacks outside the lock
            if let cb = videoCb {
                for data in videoToDeliver {
                    cb(data)
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

    /// Connect to a LAN-discovered peer by injecting its local address into the DHT first.
    public func connectLocalPeer(code: String, host: String, port: UInt16) {
        sendCommand(.connectLocalPeer, json: ["code": code, "host": host, "port": port])
    }

    public func disconnect(peerKeyHex: String) {
        sendCommand(.disconnect, json: ["peerKeyHex": peerKeyHex])
    }

    /// Disconnect all peers and leave all swarm topics.
    public func disconnectAllPeers() {
        sendCommand(.disconnect, json: ["peerKeyHex": "*"])
    }

    /// Maximum payload size per IPC chunk. Must be well under the pipe buffer (64KB on macOS).
    /// Each chunk becomes a separate IPC frame: 4B length + 1B type + payload.
    private static let maxChunkPayload = 16_000

    public func sendStreamData(streamId: UInt32, channel: UInt8, data: Data) {
        // Send entire frame as one IPC message (no chunking).
        // The worklet handles large IPC frames fine (4-byte length prefix, no size limit).
        // Previous chunking split frames into 16KB pieces, but concurrent encoder
        // callbacks caused chunks from different frames to interleave on the write
        // queue — the worklet's chunk reassembly failed because a new frame's chunk 0
        // replaced the previous frame's incomplete buffer.
        var payload = Data(capacity: 7 + data.count)
        var sid = streamId.bigEndian
        payload.append(Data(bytes: &sid, count: 4))
        payload.append(channel)
        payload.append(0) // totalChunks high byte (0 = unchunked)
        payload.append(0) // totalChunks low byte
        payload.append(data)
        sendCommand(.streamData, binary: payload)
    }

    public func requestStatus() {
        sendCommand(.statusRequest)
    }

    public func lookupPeer(code: String) {
        sendCommand(.lookupPeer, json: ["code": code])
    }

    public func sendCachedDhtNodes(_ nodes: [[String: Any]], keypair: (publicKey: String, secretKey: String)? = nil) {
        var payload: [String: Any] = ["nodes": nodes]
        if let kp = keypair {
            payload["keypair"] = ["publicKey": kp.publicKey, "secretKey": kp.secretKey]
        }
        sendCommand(.cachedDhtNodes, json: payload)
    }

    public func sendSuspend() {
        sendCommand(.suspend)
    }

    public func sendResume() {
        sendCommand(.resume)
    }

    public func sendReannounce() {
        sendCommand(.reannounce)
    }

    public func sendApprovePeer(peerKeyHex: String) {
        sendCommand(.approvePeer, json: ["peerKeyHex": peerKeyHex])
    }

    /// Clear OTA worklet bundle from Documents (for debugging or rollback).
    public func clearOtaBundle() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: docsDir.appendingPathComponent("worklet-ota.bundle"))
        try? FileManager.default.removeItem(at: docsDir.appendingPathComponent("worklet-ota.version"))
        NSLog("[bare] Cleared OTA worklet bundle")
    }

    /// Whether the worklet is alive and has an IPC pipe.
    public var isAlive: Bool { worklet != nil && ipc != nil }

    /// Diagnostic summary for heartbeat logging.
    public func diagnosticSummary() -> String {
        return "ipcReads=\(ipcReadCount) streamDataRecv=\(streamDataRecvCount) ch=\(ch0RecvCount)/\(ch1RecvCount)/\(ch2RecvCount)/\(chOtherRecvCount) recvBuf=\(recvBuf.count - recvBufOffset) pendingWrite=\(pendingWrite.count) chunkBufs=\(chunkBuffers.count) assembled=\(chunkAssembledCount) replaced=\(chunkReplacedCount) unchunked=\(unchunkedCount) orphaned=\(orphanedChunkCount) ch0chunked=\(ch0ChunkedCount) dropped=\(droppedFrameCount) ch0gate=\(ch0DropCount)"
    }

    /// Save DHT keypair to Keychain instead of UserDefaults.
    static func saveDhtKeypairToKeychain(publicKey: String, secretKey: String) {
        let service = "com.peariscope.dht"
        let account = "dht-keypair"
        let payload: [String: String] = ["publicKey": publicKey, "secretKey": secretKey]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[bare] Failed to save DHT keypair to Keychain: %d", status)
        }
    }

    public func terminate() {
        let w = worklet
        let i = ipc
        worklet = nil
        ipc = nil
        writeQueue.async { [self] in
            pendingWrite.removeAll()
        }
        w?.terminate()
        i?.close()
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

        writeQueue.async { [self] in
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
                handleStreamDataInPlace(at: frameStart, length: length)
            } else {
                let frame = recvBuf.subdata(in: frameStart..<(frameStart + length))
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
    /// Supports both binary format (jsonLen==0) and legacy JSON format.
    private func handleStreamDataInPlace(at offset: Int, length: Int) {
        streamDataRecvCount += 1
        // Need at least: type(1) + jsonLen(2)
        guard length >= 3 else { return }

        let restOffset = offset + 1
        let restCount = length - 1
        let jsonLen = Int(recvBuf.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: restOffset, as: UInt16.self).bigEndian
        })

        if jsonLen == 0 {
            // Binary format: [2B 0x0000] [4B streamId BE] [1B channel] [2B totalChunks BE] [2B chunkIndex BE] [payload]
            // restCount must be >= 2 + 4 + 1 + 2 + 2 = 11
            guard restCount >= 11 else { return }
            let headerBase = restOffset + 2
            let streamId = recvBuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: headerBase, as: UInt32.self).bigEndian }
            let channel = recvBuf[headerBase + 4]
            let totalChunks = Int(recvBuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: headerBase + 5, as: UInt16.self).bigEndian })
            let chunkIndex = Int(recvBuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: headerBase + 7, as: UInt16.self).bigEndian })
            let isChunked = totalChunks > 1
            let binaryStart = headerBase + 9
            let binaryEnd = offset + length
            processStreamData(streamId: streamId, channel: channel, isChunked: isChunked,
                              totalChunks: totalChunks, chunkIndex: chunkIndex,
                              binaryStart: binaryStart, binaryEnd: binaryEnd)
        } else {
            // Legacy JSON format: [2B jsonLen] [JSON] [payload]
            guard restCount >= 2 + jsonLen else { return }
            let jsonData = recvBuf.subdata(in: (restOffset + 2)..<(restOffset + 2 + jsonLen))
            guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
            let streamId = UInt32(json["streamId"] as? Int ?? 0)
            let channel = UInt8(json["channel"] as? Int ?? 0)
            let totalChunks = json["_totalChunks"] as? Int ?? 0
            let isChunked = totalChunks > 1
            let chunkIndex = json["_chunkIndex"] as? Int ?? 0
            let binaryStart = restOffset + 2 + jsonLen
            let binaryEnd = offset + length
            processStreamData(streamId: streamId, channel: channel, isChunked: isChunked,
                              totalChunks: totalChunks, chunkIndex: chunkIndex,
                              binaryStart: binaryStart, binaryEnd: binaryEnd)
        }
    }

    /// Common stream data processing for both binary and JSON formats.
    /// Handles per-channel counting, ch0 time gating, chunk assembly, and event delivery.
    private func processStreamData(streamId: UInt32, channel: UInt8, isChunked: Bool,
                                   totalChunks: Int, chunkIndex: Int,
                                   binaryStart: Int, binaryEnd: Int) {
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
            if ch0ChunkedCount <= 30 {
                NSLog("[bare-ipc] ch0 CHUNK: idx=%d/%d sid=%d binLen=%d count=%d ch0gated=%d accepted=%d",
                      chunkIndex, totalChunks, streamId, binaryEnd - binaryStart,
                      ch0ChunkedCount, ch0DropCount, lastCh0FrameAccepted ? 1 : 0)
            }
        }

        // Channel 0 time gate — gates chunk-0/unchunked by time, and non-zero chunks
        // based on whether their chunk-0 was accepted.
        // KEYFRAMES ARE NEVER DROPPED — missing keyframes cause blocky corruption
        // and frozen regions until the next keyframe arrives (~1 second later).
        if channel == 0 {
            let isChunk0 = isChunked && chunkIndex == 0
            if !isChunked || isChunk0 {
                // Detect keyframes by inspecting first NAL unit type after Annex B start code.
                // H.265: VPS=32, SPS=33, PPS=34, IDR_W_RADL=19, IDR_N_LP=20
                // H.264: SPS=7, PPS=8, IDR=5
                let isKeyframe = Self.isKeyframeData(recvBuf, offset: binaryStart, end: binaryEnd)

                let now = CFAbsoluteTimeGetCurrent()
                if !isKeyframe && now - lastCh0AcceptTime < Self.ch0MinInterval {
                    ch0DropCount += 1
                    lastCh0FrameAccepted = false
                    if ch0DropCount <= 5 {
                        let msg = "ch0 GATE DROP: isChunk0=\(isChunk0) elapsed=\(String(format: "%.4f", now - lastCh0AcceptTime))s"
                        NSLog("[bare-ipc] %@", msg)
                        onLog?(msg)
                    }
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

        if isChunked {
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
            buf.add(index: chunkIndex, data: binaryData)
            chunkBuffers[key] = buf
            if buf.isComplete {
                chunkAssembledCount += 1
                let assembled = buf.assemble()
                chunkBuffers.removeValue(forKey: key)
                // Defer ch0 video callback until after recvLock is released.
                if channel == 0 && onCh0VideoData != nil {
                    pendingVideoData.append(assembled)
                }
                let event = BareStreamDataEvent(
                    streamId: streamId,
                    channel: channel,
                    data: assembled
                )
                onStreamData?(event)
            }
        } else {
            let binaryData = recvBuf.subdata(in: binaryStart..<binaryEnd)
            unchunkedCount += 1
            // Defer ch0 video callback until after recvLock is released
            if channel == 0 && onCh0VideoData != nil {
                pendingVideoData.append(binaryData)
            }
            let event = BareStreamDataEvent(
                streamId: streamId,
                channel: channel,
                data: binaryData
            )
            onStreamData?(event)
        }
    }

    /// Deliver stream data from the handleFrame fallback path (Data already extracted).
    /// Shares time gating and chunk assembly logic with processStreamData but works
    /// with pre-extracted Data instead of recvBuf offsets.
    private func deliverStreamData(streamId: UInt32, channel: UInt8, isChunked: Bool,
                                   totalChunks: Int, chunkIndex: Int, binaryData: Data) {
        // Per-channel counting
        switch channel {
        case 0: ch0RecvCount += 1
        case 1: ch1RecvCount += 1
        case 2: ch2RecvCount += 1
        default: chOtherRecvCount += 1
        }

        if channel == 0 && isChunked {
            ch0ChunkedCount += 1
        }

        // Channel 0 time gate — keyframes are never dropped
        if channel == 0 {
            let isChunk0 = isChunked && chunkIndex == 0
            if !isChunked || isChunk0 {
                let isKeyframe = binaryData.withUnsafeBytes { ptr -> Bool in
                    guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    return Self.isKeyframeBytes(base, count: binaryData.count)
                }
                let now = CFAbsoluteTimeGetCurrent()
                if !isKeyframe && now - lastCh0AcceptTime < Self.ch0MinInterval {
                    ch0DropCount += 1
                    lastCh0FrameAccepted = false
                    return
                }
                lastCh0AcceptTime = now
                lastCh0FrameAccepted = true
            } else if isChunked && !lastCh0FrameAccepted {
                ch0DropCount += 1
                return
            }
        }

        if isChunked {
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
            buf.add(index: chunkIndex, data: binaryData)
            chunkBuffers[key] = buf
            if buf.isComplete {
                chunkAssembledCount += 1
                let assembled = buf.assemble()
                chunkBuffers.removeValue(forKey: key)
                if channel == 0 && onCh0VideoData != nil {
                    pendingVideoData.append(assembled)
                }
                let event = BareStreamDataEvent(streamId: streamId, channel: channel, data: assembled)
                onStreamData?(event)
            }
        } else {
            unchunkedCount += 1
            if channel == 0 && onCh0VideoData != nil {
                pendingVideoData.append(binaryData)
            }
            let event = BareStreamDataEvent(streamId: streamId, channel: channel, data: binaryData)
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
                    connectionCode: json["connectionCode"] as? String ?? "",
                    dhtPort: UInt16(json["dhtPort"] as? Int ?? 0)
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
            // Fallback path for streamData not caught by the in-place hot path.
            // Supports both binary format (jsonLen==0) and legacy JSON format.
            streamDataRecvCount += 1
            guard rest.count >= 2 else { break }
            let jsonLen = Int(rest.withUnsafeBytes { ptr -> UInt16 in
                ptr.load(as: UInt16.self).bigEndian
            })
            if jsonLen == 0 {
                // Binary format: [2B 0x0000] [4B streamId] [1B channel] [2B totalChunks] [2B chunkIndex] [payload]
                guard rest.count >= 11 else { break }
                let streamId = rest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt32.self).bigEndian }
                let channel = rest[6]
                let totalChunks = Int(rest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 7, as: UInt16.self).bigEndian })
                let chunkIndex = Int(rest.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: UInt16.self).bigEndian })
                let isChunked = totalChunks > 1
                let binaryData = rest.subdata(in: 11..<rest.count)
                deliverStreamData(streamId: streamId, channel: channel, isChunked: isChunked,
                                  totalChunks: totalChunks, chunkIndex: chunkIndex, binaryData: binaryData)
            } else {
                // Legacy JSON format
                guard rest.count >= 2 + jsonLen else { break }
                let jsonData = rest.subdata(in: 2..<(2 + jsonLen))
                guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { break }
                let streamId = UInt32(json["streamId"] as? Int ?? 0)
                let channel = UInt8(json["channel"] as? Int ?? 0)
                let totalChunks = json["_totalChunks"] as? Int ?? 0
                let isChunked = totalChunks > 1
                let chunkIndex = json["_chunkIndex"] as? Int ?? 0
                let binaryData = rest.subdata(in: (2 + jsonLen)..<rest.count)
                deliverStreamData(streamId: streamId, channel: channel, isChunked: isChunked,
                                  totalChunks: totalChunks, chunkIndex: chunkIndex, binaryData: binaryData)
            }

        case .statusResponse:
            if let json = parseJSON(rest) {
                let event = BareStatusEvent(
                    isHosting: json["isHosting"] as? Bool ?? false,
                    isConnected: json["isConnected"] as? Bool ?? false,
                    connectionCode: json["connectionCode"] as? String,
                    publicKeyHex: json["publicKeyHex"] as? String,
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
                onLog?(msg)
            }

        case .lookupResult:
            if let json = parseJSON(rest) {
                let code = json["code"] as? String ?? ""
                let online = json["online"] as? Bool ?? false
                onLookupResult?(code, online)
            }

        case .dhtNodes:
            if let json = parseJSON(rest) {
                if let nodes = json["nodes"] as? [[String: Any]] {
                    onDhtNodes?(nodes)
                }
                // Save keypair from worklet for persistence across launches
                if let kp = json["keypair"] as? [String: String],
                   let pubKey = kp["publicKey"], let secKey = kp["secretKey"] {
                    Self.saveDhtKeypairToKeychain(publicKey: pubKey, secretKey: secKey)
                    NSLog("[bare] Saved DHT keypair for persistence: %@...", String(pubKey.prefix(16)))
                }
            }

        case .otaUpdateAvailable:
            // Frame format: [jsonLen: 2B BE] [JSON bytes] [binary bundle data]
            guard rest.count >= 2 else { break }
            let jsonLen = Int(rest[rest.startIndex]) << 8 | Int(rest[rest.startIndex + 1])
            guard rest.count >= 2 + jsonLen else { break }
            let jsonData = rest.subdata(in: (rest.startIndex + 2)..<(rest.startIndex + 2 + jsonLen))
            let binaryPayload = rest.subdata(in: (rest.startIndex + 2 + jsonLen)..<rest.endIndex)
            if let otaJson = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let version = otaJson["version"] as? String ?? "unknown"
                if !binaryPayload.isEmpty {
                    onOtaUpdate?(version, binaryPayload)
                }
            }

        case .connectionStatus:
            if let json = parseJSON(rest) {
                let phase = json["phase"] as? String ?? ""
                let detail = json["detail"] as? String ?? ""
                onConnectionStatus?(phase, detail)
            }
        }
    }

    private func parseJSON(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Detect keyframes in Annex B data by inspecting the first NAL unit type.
    /// Works with both recvBuf offsets (processStreamData) and raw bytes (deliverStreamData).
    /// H.265: VPS=32, SPS=33, PPS=34, IDR_W_RADL=19, IDR_N_LP=20
    /// H.264: SPS=7, PPS=8, IDR=5
    private static func isKeyframeData(_ data: Data, offset: Int, end: Int) -> Bool {
        let count = end - offset
        guard count >= 5 else { return false }
        return data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isKeyframeBytes(base + offset, count: count)
        }
    }

    private static func isKeyframeBytes(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count >= 5 else { return false }
        var nalByte: UInt8 = 0
        if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1 {
            nalByte = bytes[4]
        } else if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 && count >= 4 {
            nalByte = bytes[3]
        } else {
            return false
        }
        let h265type = (nalByte >> 1) & 0x3F
        let h264type = nalByte & 0x1F
        // H.265 VPS=32, SPS=33, PPS=34, IDR_W_RADL=19, IDR_N_LP=20
        // H.264 SPS=7, PPS=8, IDR=5
        return (h265type >= 32 && h265type <= 34) || h265type == 19 || h265type == 20 ||
               h264type == 5 || h264type == 7 || h264type == 8
    }
}
