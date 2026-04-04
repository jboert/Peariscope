import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Monitors the local clipboard and shares text/image changes with remote peers.
/// Receives clipboard data from remote peers and applies it locally.
public final class ClipboardSharing: @unchecked Sendable {
    public var onClipboardChanged: ((String) -> Void)?
    public var onImageClipboardChanged: ((Data) -> Void)?

    private var isMonitoring = false
    private var lastKnownText: String?
    private var lastKnownImageHash: Int = 0
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0
    /// Suppresses the next local clipboard check after we apply remote data,
    /// so we don't echo it back to the sender.
    private var suppressNextCheck = false

    /// Maximum clipboard text size (1MB)
    public static let maxClipboardSize = 1024 * 1024
    /// Maximum clipboard image size (10MB)
    public static let maxImageSize = 10 * 1024 * 1024

    public init() {}

    /// Start monitoring the local clipboard for changes
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastKnownText = currentClipboardText()
        lastKnownImageHash = currentImageHash()

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
        suppressNextCheck = true
        lastKnownText = text
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// Apply clipboard image (PNG) received from a remote peer
    public func applyRemoteImage(_ pngData: Data) {
        guard pngData.count <= Self.maxImageSize else {
            NSLog("[clipboard] Rejected remote image: size %d exceeds max %d", pngData.count, Self.maxImageSize)
            return
        }
        suppressNextCheck = true
        lastKnownImageHash = pngData.hashValue
        #if canImport(AppKit)
        guard let image = NSImage(data: pngData) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #elseif canImport(UIKit)
        guard let image = UIImage(data: pngData) else { return }
        UIPasteboard.general.image = image
        #endif
    }

    private func checkClipboard() {
        if suppressNextCheck {
            suppressNextCheck = false
            return
        }

        // Check for image changes first (images take priority over text
        // since copying an image often also puts text on the clipboard)
        let imgHash = currentImageHash()
        if imgHash != 0 && imgHash != lastKnownImageHash {
            lastKnownImageHash = imgHash
            if let pngData = currentImageAsPNG(), pngData.count <= Self.maxImageSize {
                onImageClipboardChanged?(pngData)
                return
            }
        }

        // Check text
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

    /// Quick hash to detect image clipboard changes without reading full data
    private func currentImageHash() -> Int {
        #if canImport(AppKit)
        // Check changeCount — increments on every pasteboard change
        let pb = NSPasteboard.general
        guard pb.types?.contains(.png) == true || pb.types?.contains(.tiff) == true else { return 0 }
        return pb.changeCount
        #elseif canImport(UIKit)
        guard UIPasteboard.general.hasImages else { return 0 }
        return UIPasteboard.general.changeCount
        #else
        return 0
        #endif
    }

    /// Read the current clipboard image as PNG data
    private func currentImageAsPNG() -> Data? {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        // Try PNG first, then TIFF
        if let pngData = pb.data(forType: .png) {
            return pngData
        }
        if let tiffData = pb.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let tiffRep = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffRep),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }
        return nil
        #elseif canImport(UIKit)
        guard let image = UIPasteboard.general.image else { return nil }
        return image.pngData()
        #else
        return nil
        #endif
    }
}
