import Foundation
import Combine

/// Handles automatic reconnection when a peer disconnects unexpectedly.
/// Uses exponential backoff with jitter.
public final class ReconnectionManager: ObservableObject, @unchecked Sendable {
    public enum ReconnectState: Equatable {
        case idle
        case reconnecting(attempt: Int, max: Int)
        case failed
    }

    @Published public var state: ReconnectState = .idle

    public struct PeerRecord: Sendable {
        public let connectionCode: String
        public let peerKey: Data
        public var attempts: Int
        public var lastAttempt: Date
    }

    public var onReconnectAttempt: ((PeerRecord) -> Void)?
    public var onReconnectGaveUp: ((PeerRecord) -> Void)?

    private var disconnectedPeers: [String: PeerRecord] = [:] // keyed by peerKey hex
    private let maxAttempts = 5
    private let baseDelay: TimeInterval = 2.0
    private let maxDelay: TimeInterval = 30.0
    private var timers: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    public init() {}

    /// Register a peer for reconnection attempts
    public func peerDisconnected(code: String, peerKey: Data) {
        let keyHex = peerKey.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            let record = PeerRecord(connectionCode: code, peerKey: peerKey, attempts: 0, lastAttempt: Date())
            disconnectedPeers[keyHex] = record
        }
        DispatchQueue.main.async { self.state = .reconnecting(attempt: 1, max: self.maxAttempts) }
        scheduleReconnect(keyHex: keyHex)
    }

    /// Call when peer successfully reconnects — cancels further attempts
    public func peerReconnected(peerKey: Data) {
        let keyHex = peerKey.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            disconnectedPeers.removeValue(forKey: keyHex)
            timers[keyHex]?.cancel()
            timers.removeValue(forKey: keyHex)
        }
    }

    /// Cancel all reconnection attempts
    public func cancelAll() {
        lock.withLock {
            for (_, task) in timers { task.cancel() }
            timers.removeAll()
            disconnectedPeers.removeAll()
        }
        DispatchQueue.main.async { self.state = .idle }
    }

    private func scheduleReconnect(keyHex: String) {
        let (record, shouldGiveUp) = lock.withLock { () -> (PeerRecord?, Bool) in
            guard var record = disconnectedPeers[keyHex] else {
                return (nil, false)
            }
            if record.attempts >= maxAttempts {
                disconnectedPeers.removeValue(forKey: keyHex)
                return (record, true)
            }
            record.attempts += 1
            disconnectedPeers[keyHex] = record
            return (record, false)
        }

        guard let record else { return }
        if shouldGiveUp {
            DispatchQueue.main.async { self.state = .failed }
            onReconnectGaveUp?(record)
            return
        }

        DispatchQueue.main.async { self.state = .reconnecting(attempt: record.attempts, max: self.maxAttempts) }

        // Exponential backoff with jitter
        let delay = min(baseDelay * pow(2.0, Double(record.attempts - 1)), maxDelay)
        let jitter = Double.random(in: 0...delay * 0.3)
        let totalDelay = delay + jitter

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(totalDelay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let currentRecord = self.lock.withLock { self.disconnectedPeers[keyHex] }
            guard let currentRecord else { return }
            self.onReconnectAttempt?(currentRecord)
            self.scheduleReconnect(keyHex: keyHex)
        }

        lock.withLock {
            timers[keyHex] = task
        }
    }
}
