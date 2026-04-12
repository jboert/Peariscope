import Foundation

/// Monitors network conditions and adjusts encoding parameters for optimal quality.
/// Uses RTT, packet loss, throughput, jitter, and decode FPS to make decisions.
/// Employs EWMA smoothing and hysteresis to avoid oscillation.
public final class AdaptiveQuality: @unchecked Sendable {
    public struct Settings: Sendable {
        public var bitrate: Int
        public var resolutionScale: Float  // 1.0 = full, 0.5 = half
        public var fps: Int
        public var codec: Codec

        public enum Codec: Sendable {
            case h264
            case h265
        }
    }

    public struct NetworkStats: Sendable {
        public var rttMs: Double
        public var packetLoss: Double  // 0.0 - 1.0
        public var throughputKbps: Double
        public var decodeFps: Double
        public var receivedKbps: Double  // Viewer's actual received throughput
        public var jitterMs: Double      // Inter-frame arrival jitter

        public init(rttMs: Double = 0, packetLoss: Double = 0, throughputKbps: Double = 0,
                    decodeFps: Double = 0, receivedKbps: Double = 0, jitterMs: Double = 0) {
            self.rttMs = rttMs
            self.packetLoss = packetLoss
            self.throughputKbps = throughputKbps
            self.decodeFps = decodeFps
            self.receivedKbps = receivedKbps
            self.jitterMs = jitterMs
        }
    }

    public var onSettingsChanged: ((Settings) -> Void)?

    private var currentSettings: Settings
    private var lastStats = NetworkStats()

    // EWMA-smoothed metrics (alpha = 0.3 for responsiveness)
    private var smoothRtt: Double = 0
    private var smoothLoss: Double = 0
    private var smoothThroughput: Double = 0  // kbps
    private var smoothJitter: Double = 0
    private var smoothDecodeFps: Double = 60
    private let alpha: Double = 0.3

    // State tracking for hysteresis
    private var consecutiveGoodUpdates: Int = 0
    private var consecutiveBadUpdates: Int = 0
    private var updateCount: Int = 0

    // RTT thresholds — relaxed for relay/5G connections with naturally higher latency
    private let goodRtt: Double = 100      // ms — great conditions
    private let highRtt: Double = 250      // ms — start being cautious
    private let criticalRtt: Double = 500  // ms — aggressive reduction

    // Loss thresholds — relaxed, minor loss is normal on cellular/relay
    private let highLoss: Double = 0.08    // 8% — start reducing
    private let criticalLoss: Double = 0.20 // 20% — aggressive reduction

    // Jitter thresholds — relaxed for cellular
    private let highJitter: Double = 80    // ms
    private let criticalJitter: Double = 150 // ms

    // Bitrate bounds
    private let minBitrate = 8_000_000     // 8 Mbps
    private let maxBitrate = 80_000_000    // 80 Mbps
    private let defaultBitrate = 30_000_000 // 30 Mbps

    // Hysteresis: need N consecutive good/bad readings before changing
    private let upgradeThreshold = 2   // 2 good updates before increasing quality
    private let downgradeThreshold = 2 // Require 2 bad readings before reducing (avoid flapping)

    public init(preferH265: Bool = false) {
        currentSettings = Settings(
            bitrate: defaultBitrate,
            resolutionScale: 1.0,
            fps: 60,
            codec: preferH265 ? .h265 : .h264
        )
    }

    /// Update with latest network measurements
    public func update(stats: NetworkStats) {
        lastStats = stats
        updateCount += 1

        // EWMA smoothing — first update seeds directly
        if updateCount == 1 {
            smoothRtt = stats.rttMs
            smoothLoss = stats.packetLoss
            smoothThroughput = stats.receivedKbps > 0 ? stats.receivedKbps : stats.throughputKbps
            smoothJitter = stats.jitterMs
            smoothDecodeFps = stats.decodeFps > 0 ? stats.decodeFps : 60
        } else {
            if stats.rttMs > 0 { smoothRtt = smoothRtt * (1 - alpha) + stats.rttMs * alpha }
            smoothLoss = smoothLoss * (1 - alpha) + stats.packetLoss * alpha
            if stats.receivedKbps > 0 {
                smoothThroughput = smoothThroughput * (1 - alpha) + stats.receivedKbps * alpha
            }
            if stats.jitterMs > 0 {
                smoothJitter = smoothJitter * (1 - alpha) + stats.jitterMs * alpha
            }
            if stats.decodeFps > 0 {
                smoothDecodeFps = smoothDecodeFps * (1 - alpha) + stats.decodeFps * alpha
            }
        }

        let quality = assessQuality()
        updateConsecutiveCounts(quality)

        let newSettings = computeSettings(quality: quality)
        if newSettings != currentSettings {
            currentSettings = newSettings
            onSettingsChanged?(newSettings)
        }
    }

    /// Get current settings
    public var settings: Settings { currentSettings }

    /// Force a specific codec
    public func setCodec(_ codec: Settings.Codec) {
        currentSettings.codec = codec
        onSettingsChanged?(currentSettings)
    }

    // MARK: - Quality Assessment

    private enum QualityLevel {
        case excellent  // Can increase quality
        case good       // Maintain current
        case degraded   // Reduce moderately
        case critical   // Reduce aggressively
    }

    private func assessQuality() -> QualityLevel {
        // Critical conditions — any one triggers aggressive reduction
        if smoothLoss > criticalLoss { return .critical }
        if smoothRtt > criticalRtt { return .critical }
        if smoothJitter > criticalJitter { return .critical }
        if smoothDecodeFps > 0 && smoothDecodeFps < 20 { return .critical }

        // Degraded conditions
        if smoothLoss > highLoss { return .degraded }
        if smoothRtt > highRtt { return .degraded }
        if smoothJitter > highJitter { return .degraded }
        if smoothDecodeFps > 0 && smoothDecodeFps < Double(currentSettings.fps) * 0.6 { return .degraded }

        // Check throughput — if viewer receives significantly less than we send
        let currentBitrateKbps = Double(currentSettings.bitrate) / 1000.0
        if smoothThroughput > 0 && smoothThroughput < currentBitrateKbps * 0.5 {
            return .degraded
        }

        // Good conditions
        if smoothRtt < goodRtt && smoothLoss < 0.01 && smoothJitter < 15 {
            return .excellent
        }

        return .good
    }

    private func updateConsecutiveCounts(_ quality: QualityLevel) {
        switch quality {
        case .excellent:
            consecutiveGoodUpdates += 1
            consecutiveBadUpdates = 0
        case .good:
            // Don't reset good count, but don't increment either
            consecutiveBadUpdates = 0
        case .degraded, .critical:
            consecutiveBadUpdates += 1
            consecutiveGoodUpdates = 0
        }
    }

    private func computeSettings(quality: QualityLevel) -> Settings {
        var s = currentSettings

        switch quality {
        case .critical:
            if consecutiveBadUpdates >= downgradeThreshold {
                // Aggressive: halve bitrate, drop to 30fps, half resolution
                s.bitrate = max(minBitrate, s.bitrate * 1 / 2)
                s.fps = 30
                s.resolutionScale = max(0.5, s.resolutionScale - 0.25)
                consecutiveBadUpdates = 0  // Reset after acting
            }

        case .degraded:
            if consecutiveBadUpdates >= downgradeThreshold {
                // Moderate: reduce bitrate by 20%
                s.bitrate = max(minBitrate, s.bitrate * 4 / 5)
                // Only drop fps/resolution if sustained
                if consecutiveBadUpdates >= 3 {
                    s.fps = 30
                    s.resolutionScale = max(0.75, s.resolutionScale - 0.125)
                }
                consecutiveBadUpdates = 0
            }

        case .excellent:
            if consecutiveGoodUpdates >= upgradeThreshold {
                // Faster recovery: +25% bitrate, restore fps/resolution
                s.bitrate = min(maxBitrate, s.bitrate * 5 / 4)
                s.fps = 60
                s.resolutionScale = min(1.0, s.resolutionScale + 0.25)
                consecutiveGoodUpdates = 0  // Reset after acting
            }

        case .good:
            // Maintain current settings, but restore fps/resolution
            if s.fps < 60 { s.fps = 60 }
            if s.resolutionScale < 1.0 {
                s.resolutionScale = min(1.0, s.resolutionScale + 0.125)
            }
        }

        // Throughput cap: never send more than viewer can receive (with 20% headroom)
        if smoothThroughput > 0 {
            let throughputCap = Int(smoothThroughput * 1.2) * 1000  // kbps → bps with headroom
            s.bitrate = min(s.bitrate, max(minBitrate, throughputCap))
        }

        return s
    }
}

extension AdaptiveQuality.Settings: Equatable {}
