import Foundation
import Network
import SwiftProtobuf

/// IPC client that connects to the Pear runtime via Unix domain socket.
/// Speaks length-prefixed protobuf frames.
public final class IpcClient: @unchecked Sendable {
    private let socketPath: String
    private var connection: (any ConnectionWrapper)?
    private var nextRequestId: UInt32 = 1
    private var pendingCallbacks: [UInt32: (Peariscope_IpcMessage) -> Void] = [:]
    private let queue = DispatchQueue(label: "peariscope.ipc", qos: .userInteractive)

    public var onPeerConnected: ((Peariscope_PeerConnected) -> Void)?
    public var onPeerDisconnected: ((Peariscope_PeerDisconnected) -> Void)?
    public var onStreamData: ((Peariscope_StreamData) -> Void)?
    public var onConnectionEstablished: ((Peariscope_ConnectionEstablished) -> Void)?
    public var onConnectionFailed: ((Peariscope_ConnectionFailed) -> Void)?
    public var onError: ((Peariscope_Error) -> Void)?

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? Self.defaultSocketPath()
    }

    private static func defaultSocketPath() -> String {
        // Use app-scoped directory instead of world-accessible /tmp
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("Peariscope")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("peariscope.sock").path
        }
        // Fallback to user-scoped tmp
        let userTmp = NSTemporaryDirectory()
        return (userTmp as NSString).appendingPathComponent("peariscope.sock")
    }

    /// Connect to the Pear runtime IPC server via Unix domain socket
    public func connect() async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IpcError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for i in 0..<min(pathBytes.count, 104) {
                    dest[i] = pathBytes[i]
                }
                return true
            }
            _ = bound
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            throw IpcError.connectionFailed(errno: errno)
        }

        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        setupConnection(fileHandle: fileHandle)
    }

    /// Connect to the Pear runtime via TCP using Network.framework (for iOS connecting to macOS relay)
    public func connectTcp(host: String, port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let nwConnection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )

            nwConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self else {
                        continuation.resume(throwing: IpcError.notConnected)
                        return
                    }
                    self.nwTcpConnection = nwConnection
                    self.setupTcpReading(nwConnection)
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: IpcError.tcpConnectionFailed(error.localizedDescription))
                case .waiting(let error):
                    nwConnection.cancel()
                    continuation.resume(throwing: IpcError.tcpConnectionFailed("waiting: \(error.localizedDescription)"))
                default:
                    break
                }
            }

            nwConnection.start(queue: self.queue)
        }
    }

    private var nwTcpConnection: NWConnection?

    private func setupTcpReading(_ nwConn: NWConnection) {
        let wrapper = NWTcpConnectionWrapper(connection: nwConn, queue: queue)
        wrapper.onMessage = { [weak self] data in
            self?.handleMessage(data)
        }
        wrapper.startReading()
        connection = wrapper
    }

    private func setupConnection(fileHandle: FileHandle) {
        let wrapper = FileHandleConnectionWrapper(fileHandle: fileHandle, queue: queue)
        wrapper.onMessage = { [weak self] data in
            self?.handleMessage(data)
        }
        wrapper.startReading()
        connection = wrapper
    }

    /// Send a request and get a response
    public func request(_ build: sending (inout Peariscope_IpcMessage) -> Void) async throws -> Peariscope_IpcMessage {
        let id = queue.sync { () -> UInt32 in
            let id = nextRequestId
            nextRequestId += 1
            return id
        }

        var msg = Peariscope_IpcMessage()
        msg.id = id
        build(&msg)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                self?.pendingCallbacks[id] = { response in
                    continuation.resume(returning: response)
                }
            }
            try? send(msg)
        }
    }

    /// Send a message without waiting for response (fire-and-forget)
    public func send(_ msg: Peariscope_IpcMessage) throws {
        guard let connection else {
            throw IpcError.notConnected
        }
        let data = try msg.serializedData()
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        connection.write(header + data)
    }

    private func handleMessage(_ data: Data) {
        guard let msg = try? Peariscope_IpcMessage(serializedBytes: data) else {
            return
        }

        // Check if this is a response to a pending request
        // Note: handleMessage is always called on the `queue` already, so access directly
        if msg.id != 0, let callback = pendingCallbacks.removeValue(forKey: msg.id) {
            callback(msg)
            return
        }

        // Otherwise dispatch as an event
        switch msg.payload {
        case .peerConnected(let event):
            onPeerConnected?(event)
        case .peerDisconnected(let event):
            onPeerDisconnected?(event)
        case .streamData(let event):
            onStreamData?(event)
        case .connectionEstablished(let event):
            onConnectionEstablished?(event)
        case .connectionFailed(let event):
            onConnectionFailed?(event)
        case .error(let event):
            onError?(event)
        default:
            break
        }
    }

    public func disconnect() {
        connection?.close()
        connection = nil
        nwTcpConnection?.cancel()
        nwTcpConnection = nil
    }
}

// MARK: - Connection wrapper protocol

protocol ConnectionWrapper: AnyObject, Sendable {
    var onMessage: ((Data) -> Void)? { get set }
    func startReading()
    func write(_ data: Data)
    func close()
}

// MARK: - FileHandle-based wrapper (Unix domain socket)

final class FileHandleConnectionWrapper: ConnectionWrapper, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue: DispatchQueue
    private var buffer = Data()
    var onMessage: ((Data) -> Void)?

    init(fileHandle: FileHandle, queue: DispatchQueue) {
        self.fileHandle = fileHandle
        self.queue = queue
    }

    func startReading() {
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                self?.onMessage = nil
                return
            }
            self.queue.async { [weak self] in
                self?.buffer.append(data)
                self?.drainFrames()
            }
        }
    }

    func write(_ data: Data) {
        fileHandle.write(data)
    }

    func close() {
        fileHandle.readabilityHandler = nil
        fileHandle.closeFile()
    }

    private static let maxFrameLength = 5 * 1024 * 1024

    private func drainFrames() {
        while buffer.count >= 4 {
            let length = Int(buffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            if length > Self.maxFrameLength {
                NSLog("[ipc] ERROR: frame length %d exceeds max %d, dropping buffer", length, Self.maxFrameLength)
                buffer.removeAll()
                return
            }
            guard buffer.count >= 4 + length else { break }
            let frame = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            onMessage?(frame)
        }
    }
}

// MARK: - NWConnection-based wrapper (TCP for iOS)

final class NWTcpConnectionWrapper: ConnectionWrapper, @unchecked Sendable {
    private let nwConnection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    var onMessage: ((Data) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.nwConnection = connection
        self.queue = queue
    }

    func startReading() {
        readNext()
    }

    private func readNext() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.buffer.append(content)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.onMessage = nil
                return
            }
            self.readNext()
        }
    }

    func write(_ data: Data) {
        nwConnection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        nwConnection.cancel()
    }

    private static let maxFrameLength = 5 * 1024 * 1024

    private func drainFrames() {
        while buffer.count >= 4 {
            let length = Int(buffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            if length > Self.maxFrameLength {
                NSLog("[ipc] ERROR: frame length %d exceeds max %d, dropping buffer", length, Self.maxFrameLength)
                buffer.removeAll()
                return
            }
            guard buffer.count >= 4 + length else { break }
            let frame = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            onMessage?(frame)
        }
    }
}

// MARK: - Errors

public enum IpcError: LocalizedError {
    case socketCreationFailed
    case connectionFailed(errno: Int32)
    case notConnected
    case encodingFailed
    case tcpConnectionFailed(String)
    case urlParsingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed: return "Failed to create socket"
        case .connectionFailed(let e): return "Connection failed (errno \(e))"
        case .notConnected: return "Not connected"
        case .encodingFailed: return "Encoding failed"
        case .tcpConnectionFailed(let msg): return "TCP connection failed: \(msg)"
        case .urlParsingFailed(let msg): return "URL parsing failed: \(msg)"
        }
    }
}
