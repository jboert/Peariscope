import Foundation

/// Tracks end-to-end latency from capture to display.
/// Uses timestamps embedded in frame metadata to measure the full pipeline.
public final class LatencyTracker: @unchecked Sendable {
    public struct Stats: Sendable {
        public var captureToEncodeMs: Double
        public var networkMs: Double
        public var decodeToDisplayMs: Double
        public var totalMs: Double

        public init() {
            captureToEncodeMs = 0
            networkMs = 0
            decodeToDisplayMs = 0
            totalMs = 0
        }
    }

    private var history: [Double] = []
    private let maxHistory = 60
    private let queue = DispatchQueue(label: "peariscope.latency")

    /// Current smoothed latency in milliseconds
    public private(set) var currentLatencyMs: Double = 0

    /// Rolling average latency
    public var averageLatencyMs: Double {
        queue.sync {
            guard !history.isEmpty else { return 0 }
            return history.reduce(0, +) / Double(history.count)
        }
    }

    public init() {}

    /// Record a latency measurement (total end-to-end in ms)
    public func record(latencyMs: Double) {
        queue.sync {
            history.append(latencyMs)
            if history.count > maxHistory {
                history.removeFirst()
            }
            // Exponential moving average (alpha=0.2 for smoothing)
            if currentLatencyMs == 0 {
                currentLatencyMs = latencyMs
            } else {
                currentLatencyMs = currentLatencyMs * 0.8 + latencyMs * 0.2
            }
        }
    }

    /// Generate a timestamp to embed in a frame (host side)
    public static func captureTimestamp() -> UInt64 {
        UInt64(CFAbsoluteTimeGetCurrent() * 1000)
    }

    /// Calculate latency from a capture timestamp (viewer side)
    public func measureFromTimestamp(_ captureTimestampMs: UInt64) -> Double {
        let now = UInt64(CFAbsoluteTimeGetCurrent() * 1000)
        let latency = Double(now) - Double(captureTimestampMs)
        record(latencyMs: max(0, latency))
        return max(0, latency)
    }

    public func reset() {
        queue.sync {
            history.removeAll()
            currentLatencyMs = 0
        }
    }
}
