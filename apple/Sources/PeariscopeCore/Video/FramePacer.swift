import Foundation
import CoreVideo
#if os(iOS)
import QuartzCore
#endif

/// Smooths out frame delivery jitter by buffering a small number of frames
/// and releasing them at a steady cadence.
public final class FramePacer: @unchecked Sendable {
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private let targetFps: Int
    private var frameQueue: [(CVPixelBuffer, CFAbsoluteTime)] = []
    private let maxBuffered = 3
    #if os(macOS)
    private var displayLink: CVDisplayLink?
    #else
    private var displayLink: CADisplayLink?
    #endif
    private let queue = DispatchQueue(label: "peariscope.pacer", qos: .userInteractive)
    private var isRunning = false

    public init(targetFps: Int = 60) {
        self.targetFps = targetFps
    }

    deinit {
        // Ensure display link is cleaned up if stop() wasn't called
        #if os(macOS)
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLinkRetain?.release()
        #else
        // CADisplayLink must be invalidated on the thread it was added to (main thread).
        // In deinit we can't guarantee we're on main, but with the proxy pattern,
        // the proxy's weak reference is already nil so the display link is harmless.
        if let link = displayLink {
            DispatchQueue.main.async { link.invalidate() }
        }
        #endif
    }

    /// Enqueue a decoded frame for paced delivery
    public func enqueue(pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        queue.async { [weak self] in
            guard let self else { return }
            self.frameQueue.append((pixelBuffer, now))
            // Drop oldest frames if buffer is full
            while self.frameQueue.count > self.maxBuffered {
                self.frameQueue.removeFirst()
            }
            // If no display link, deliver immediately
            if !self.isRunning {
                self.deliverNextFrame()
            }
        }
    }

    #if os(macOS)
    /// Prevent FramePacer from being deallocated while CVDisplayLink callback is active.
    /// CVDisplayLink uses an Unmanaged pointer — we must ensure the FramePacer stays alive.
    private var displayLinkRetain: Unmanaged<FramePacer>?
    #else
    /// Weak-target proxy to avoid CADisplayLink retaining FramePacer directly.
    /// CADisplayLink strongly retains its target — without a proxy, the FramePacer
    /// can't be deallocated until the display link is invalidated (which happens async).
    private class DisplayLinkProxy {
        weak var pacer: FramePacer?
        @objc func tick() { pacer?.displayLinkFired() }
    }
    private var displayLinkProxy: DisplayLinkProxy?
    #endif

    /// Start the frame pacer with a display-synced cadence
    public func start() {
        #if os(macOS)
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        // Retain self explicitly for the CVDisplayLink callback's Unmanaged pointer
        let retain = Unmanaged.passRetained(self)
        displayLinkRetain = retain

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let pacer = Unmanaged<FramePacer>.fromOpaque(userInfo!).takeUnretainedValue()
            pacer.queue.async {
                pacer.deliverNextFrame()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, retain.toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
        isRunning = true
        #else
        // iOS: use CADisplayLink with proxy target to avoid strong reference cycle
        isRunning = true
        let proxy = DisplayLinkProxy()
        proxy.pacer = self
        displayLinkProxy = proxy
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(self.targetFps), preferred: Float(self.targetFps))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
        #endif
    }

    /// Stop the frame pacer
    public func stop() {
        isRunning = false
        #if os(macOS)
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        // Release the explicit retain we took for the CVDisplayLink callback
        displayLinkRetain?.release()
        displayLinkRetain = nil
        #else
        displayLinkProxy?.pacer = nil
        if Thread.isMainThread {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.displayLink?.invalidate()
                self?.displayLink = nil
            }
        }
        #endif
        queue.sync {
            frameQueue.removeAll()
            onFrame = nil
        }
    }

    private func deliverNextFrame() {
        guard let (pixelBuffer, _) = frameQueue.first else { return }
        frameQueue.removeFirst()
        onFrame?(pixelBuffer)
    }

    #if os(iOS)
    fileprivate func displayLinkFired() {
        queue.async { [weak self] in
            self?.deliverNextFrame()
        }
    }
    #endif
}
