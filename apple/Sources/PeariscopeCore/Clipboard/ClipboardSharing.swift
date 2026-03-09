import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Monitors the local clipboard and shares text changes with remote peers.
/// Receives clipboard text from remote peers and applies it locally.
public final class ClipboardSharing: @unchecked Sendable {
    public var onClipboardChanged: ((String) -> Void)?

    private var isMonitoring = false
    private var lastKnownText: String?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    /// Maximum clipboard text size (1MB)
    public static let maxClipboardSize = 1024 * 1024

    public init() {}

    /// Start monitoring the local clipboard for changes
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastKnownText = currentClipboardText()

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    /// Stop monitoring
    public func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        isMonitoring = false
    }

    /// Apply clipboard text received from a remote peer
    public func applyRemoteClipboard(_ text: String) {
        guard text.utf8.count <= Self.maxClipboardSize else {
            NSLog("[clipboard] Rejected remote clipboard: size %d exceeds max %d", text.utf8.count, Self.maxClipboardSize)
            return
        }
        lastKnownText = text
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    private func checkClipboard() {
        let current = currentClipboardText()
        if let current, current != lastKnownText, current.utf8.count <= Self.maxClipboardSize {
            lastKnownText = current
            onClipboardChanged?(current)
        }
    }

    private func currentClipboardText() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }
}
