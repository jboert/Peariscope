import Foundation

/// Monitors network conditions and adjusts encoding parameters for optimal quality.
/// Tracks RTT, packet loss, and throughput to decide bitrate, resolution, and FPS.
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

        public init(rttMs: Double = 0, packetLoss: Double = 0, throughputKbps: Double = 0, decodeFps: Double = 0) {
            self.rttMs = rttMs
            self.packetLoss = packetLoss
            self.throughputKbps = throughputKbps
            self.decodeFps = decodeFps
        }
    }

    public var onSettingsChanged: ((Settings) -> Void)?

    private var currentSettings: Settings
    private var stats = NetworkStats()
    private var statsHistory: [NetworkStats] = []
    private let maxHistory = 5

    // Thresholds
    private let highRtt: Double = 100      // ms
    private let criticalRtt: Double = 200  // ms
    private let highLoss: Double = 0.05    // 5%
    private let criticalLoss: Double = 0.15 // 15%

    // Bitrate bounds
    private let minBitrate = 2_000_000     // 2 Mbps — floor high enough for usable quality
    private let maxBitrate = 20_000_000    // 20 Mbps
    private let defaultBitrate = 8_000_000 // 8 Mbps

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
        self.stats = stats
        statsHistory.append(stats)
        if statsHistory.count > maxHistory {
            statsHistory.removeFirst()
        }

        let newSettings = computeSettings()
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

    private func computeSettings() -> Settings {
        var s = currentSettings
        let avgLoss = statsHistory.map(\.packetLoss).reduce(0, +) / Double(max(statsHistory.count, 1))
        let avgDecodeFps = statsHistory.map(\.decodeFps).reduce(0, +) / Double(max(statsHistory.count, 1))

        // NOTE: rttMs from quality reports uses cross-device clock diff (CFAbsoluteTimeGetCurrent)
        // which is unreliable without NTP sync. Only use packet loss and decode FPS for decisions.

        // Bitrate adjustment based on packet loss
        if avgLoss > criticalLoss {
            // Critical packet loss: aggressive reduction
            s.bitrate = max(minBitrate, s.bitrate / 2)
            s.fps = 30
            s.resolutionScale = 0.5
        } else if avgLoss > highLoss {
            // Degraded: moderate reduction
            s.bitrate = max(minBitrate, s.bitrate * 3 / 4)
            s.fps = 30
            s.resolutionScale = 0.75
        } else {
            // Good conditions: gradually increase
            s.bitrate = min(maxBitrate, s.bitrate * 11 / 10)
            s.fps = 60
            s.resolutionScale = 1.0
        }

        // If decode FPS is much lower than target, reduce sending rate
        if avgDecodeFps > 0 && avgDecodeFps < Double(s.fps) * 0.7 {
            s.fps = max(15, Int(avgDecodeFps))
        }

        // Respect viewer's bitrate/fps hint (e.g. thermal throttling)
        let lastThroughput = stats.throughputKbps
        if lastThroughput > 0 {
            let hintBitrate = Int(lastThroughput) * 1000
            s.bitrate = min(s.bitrate, max(minBitrate, hintBitrate))
        }

        return s
    }
}

extension AdaptiveQuality.Settings: Equatable {}
