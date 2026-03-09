import Foundation

/// Handles automatic reconnection when a peer disconnects unexpectedly.
/// Uses exponential backoff with jitter.
public final class ReconnectionManager: @unchecked Sendable {
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
    private let queue = DispatchQueue(label: "peariscope.reconnect")

    public init() {}

    /// Register a peer for reconnection attempts
    public func peerDisconnected(code: String, peerKey: Data) {
        let keyHex = peerKey.map { String(format: "%02x", $0) }.joined()
        queue.sync {
            let record = PeerRecord(connectionCode: code, peerKey: peerKey, attempts: 0, lastAttempt: Date())
            disconnectedPeers[keyHex] = record
        }
        scheduleReconnect(keyHex: keyHex)
    }

    /// Call when peer successfully reconnects — cancels further attempts
    public func peerReconnected(peerKey: Data) {
        let keyHex = peerKey.map { String(format: "%02x", $0) }.joined()
        queue.sync {
            disconnectedPeers.removeValue(forKey: keyHex)
            timers[keyHex]?.cancel()
            timers.removeValue(forKey: keyHex)
        }
    }

    /// Cancel all reconnection attempts
    public func cancelAll() {
        queue.sync {
            for (_, task) in timers { task.cancel() }
            timers.removeAll()
            disconnectedPeers.removeAll()
        }
    }

    private func scheduleReconnect(keyHex: String) {
        let (record, shouldGiveUp) = queue.sync { () -> (PeerRecord?, Bool) in
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
            onReconnectGaveUp?(record)
            return
        }

        // Exponential backoff with jitter
        let delay = min(baseDelay * pow(2.0, Double(record.attempts - 1)), maxDelay)
        let jitter = Double.random(in: 0...delay * 0.3)
        let totalDelay = delay + jitter

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(totalDelay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let currentRecord = self.queue.sync { self.disconnectedPeers[keyHex] }
            guard let currentRecord else { return }
            self.onReconnectAttempt?(currentRecord)
            self.scheduleReconnect(keyHex: keyHex)
        }

        queue.sync {
            timers[keyHex] = task
        }
    }
}
