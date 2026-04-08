import SwiftUI
import AppKit
import Combine
import PeariscopeCore
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusCancellables = Set<AnyCancellable>()
    private var themeCancellable: AnyCancellable?
    private var viewerWindow: NSWindow?
    private var healthTimer: Timer?
    private var staleCount = 0

    let networkManager = NetworkManager()
    let hostSession: HostSession
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    override init() {
        let nm = networkManager
        hostSession = HostSession(networkManager: nm)
        super.init()
    }

    /// Prevents App Nap from suspending the worklet while hosting.
    /// Without this, macOS throttles/sleeps menu bar apps, freezing the
    /// Hyperswarm event loop and dropping DHT announcements.
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSLog("[app] applicationDidFinishLaunching — menu bar mode")

        // Disable App Nap — Peariscope needs to maintain P2P connections in background
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Maintaining P2P Hyperswarm connections for remote desktop"
        )

        // Observe host status changes (PIN prompts, etc.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.observeStatus()
        }

        // Observe theme changes to update dock icon
        themeCancellable = ThemeManager.shared.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTheme in
                self?.updateDockIcon(for: newTheme)
            }

        startRuntime()
        startHealthWatchdog()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Dock Icon

    private func updateDockIcon(for theme: AppTheme) {
        if theme == .berriscope {
            if let image = NSImage(named: "BerriscopeIcon") {
                NSApplication.shared.applicationIconImage = image
            }
        } else {
            NSApplication.shared.applicationIconImage = nil
        }
    }

    // MARK: - Status Item Icon

    /// Find the MenuBarExtra's status item and replace its icon with our custom one
    private func setupStatusItemIcon() {
        updateStatusIcon(active: hostSession.isActive)
    }

    private func updateStatusIcon(active: Bool) {
        // MenuBarExtra creates a status item — find it and update the icon
        for window in NSApplication.shared.windows {
            if let button = (window.value(forKey: "statusItem") as? NSStatusItem)?.button {
                button.image = makeStatusIcon(active: active)
                button.imagePosition = .imageOnly
                return
            }
        }

        // Fallback: search all status items in the status bar
        // The MenuBarExtra status item button can be found via the window's content
    }

    private func makeStatusIcon(active: Bool) -> NSImage {
        let height: CGFloat = 22
        let width: CGFloat = 24
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            if let appLogo = NSImage(named: "AppLogo") {
                let iconRect = NSRect(x: 1, y: 1, width: height - 2, height: height - 2)
                appLogo.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            // Status dot
            let dotSize: CGFloat = 5
            let dotRect = NSRect(
                x: rect.maxX - dotSize - 1,
                y: 1,
                width: dotSize,
                height: dotSize
            )
            let borderPath = NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1))
            NSColor.white.setFill()
            borderPath.fill()

            let dotPath = NSBezierPath(ovalIn: dotRect)
            let color = active ? NSColor(Color.pearGreen) : NSColor.systemGray
            color.setFill()
            dotPath.fill()

            return true
        }
        image.isTemplate = false
        return image
    }

    private func observeStatus() {
        hostSession.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.updateStatusIcon(active: isActive)
            }
            .store(in: &statusCancellables)

        // Show floating PIN approval panel near status bar
        hostSession.$pendingPeerPin
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pin in
                if pin != nil {
                    self?.showPinPanel()
                } else {
                    self?.dismissPinPanel()
                }
            }
            .store(in: &statusCancellables)
    }

    // MARK: - PIN Approval Panel

    private var pinPanel: NSPanel?

    private func showPinPanel() {
        // Dismiss existing panel first
        dismissPinPanel()

        guard let screen = NSScreen.main else { return }

        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 140

        let panelContent = PinApprovalPanelView(hostSession: hostSession) { [weak self] in
            self?.dismissPinPanel()
        }

        let hostingView = NSHostingView(rootView: panelContent)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position near the right side of the menu bar
        let statusBarHeight = NSStatusBar.system.thickness
        let x = screen.frame.maxX - panelWidth - 16
        let y = screen.frame.maxY - statusBarHeight - panelHeight - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        // Animate in
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.pinPanel = panel
    }

    private func dismissPinPanel() {
        guard let panel = pinPanel else { return }
        self.pinPanel = nil
        panel.orderOut(nil)
    }

    // MARK: - Viewer Window

    func openViewerWindow() {
        if let existing = viewerWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let viewerContent = ViewerWindowView(
            networkManager: networkManager,
            onClose: { [weak self] in
                self?.viewerWindow?.close()
                self?.viewerWindow = nil
            },
            onVideoSizeChanged: { [weak self] videoSize in
                self?.resizeViewerWindow(to: videoSize)
            },
            onDisconnected: { [weak self] in
                self?.resizeViewerWindowToConnect()
            },
            onWillConnect: { [weak self] in
                guard let self else { return }
                // Stop hosting before connecting as viewer.
                // Must complete before connect starts to prevent crossed connections.
                if self.hostSession.isActive {
                    NSLog("[viewer] Stopping host before connecting as viewer")
                    try? await self.hostSession.stop()
                    // Brief delay for worklet cleanup
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        )

        let hostingView = NSHostingView(rootView: viewerContent)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Peariscope — Connect"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        viewerWindow = window
    }

    private func resizeViewerWindow(to videoSize: CGSize) {
        guard let window = viewerWindow, let screen = window.screen ?? NSScreen.main else { return }

        // Account for title bar height
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height

        // Target: video size + title bar, but cap to 90% of screen
        let maxWidth = screen.visibleFrame.width * 0.9
        let maxHeight = screen.visibleFrame.height * 0.9 - titleBarHeight
        let scale = min(1.0, min(maxWidth / videoSize.width, maxHeight / videoSize.height))

        let contentWidth = videoSize.width * scale
        let contentHeight = videoSize.height * scale

        let newFrame = NSRect(
            x: screen.visibleFrame.midX - contentWidth / 2,
            y: screen.visibleFrame.midY - (contentHeight + titleBarHeight) / 2,
            width: contentWidth,
            height: contentHeight + titleBarHeight
        )
        window.setFrame(newFrame, display: true, animate: true)
        window.title = "Peariscope — \(Int(videoSize.width))x\(Int(videoSize.height))"
    }

    private func resizeViewerWindowToConnect() {
        guard let window = viewerWindow, let screen = window.screen ?? NSScreen.main else { return }
        let width: CGFloat = 420
        let height: CGFloat = 400
        let newFrame = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(newFrame, display: true, animate: true)
        window.title = "Peariscope — Connect"
    }

    // MARK: - Health Watchdog

    /// Monitors the worklet by sending STATUS_REQUEST pings and checking if the
    /// ipcReadCount increases (indicating the worklet responded).
    /// If the worklet doesn't respond for 4 consecutive checks (60 seconds),
    /// its event loop is stuck. An idle worklet (no peers) still responds to status.
    /// Note: CPU and diagnostic-string approaches were too aggressive — Hyperswarm
    /// legitimately uses 100-200% CPU, and idle worklets have unchanging diagnostics.
    private var lastIpcReadCount = 0

    private func startHealthWatchdog() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkWorkletHealth()
            }
        }
    }

    private func checkWorkletHealth() {
        guard networkManager.isWorkletAlive else {
            staleCount = 0
            lastIpcReadCount = 0
            return
        }

        let currentReads = networkManager.bareBridge.ipcReadCount

        // Check if the worklet responded to our last STATUS_REQUEST
        if currentReads == lastIpcReadCount && lastIpcReadCount > 0 {
            staleCount += 1
            NSLog("[watchdog] No IPC response (count=%d/4, reads=%d)", staleCount, currentReads)
        } else {
            staleCount = 0
        }
        lastIpcReadCount = currentReads

        // Send a STATUS_REQUEST ping — the response will increment ipcReadCount
        networkManager.bareBridge.requestStatus()

        // 4 consecutive non-responses (60 seconds) = stuck worklet
        if staleCount >= 4 {
            NSLog("[watchdog] Worklet unresponsive for %ds, restarting", staleCount * 15)
            staleCount = 0
            lastIpcReadCount = 0
            restartWorklet()
        }
    }

    private func restartWorklet() {
        let wasHosting = hostSession.isActive
        Task {
            if wasHosting {
                try? await hostSession.stop()
            }
            networkManager.shutdown()
            try? await Task.sleep(for: .seconds(1))
            try? await networkManager.startRuntime()
            if wasHosting {
                try? await hostSession.start()
            }
            NSLog("[watchdog] Worklet restarted, wasHosting=%d", wasHosting)
        }
    }

    // MARK: - Runtime

    private func startRuntime() {
        Task {
            do {
                try await networkManager.startRuntime()
            } catch {
                networkManager.lastError = "Failed to start Pear runtime: \(error.localizedDescription)"
            }

            if UserDefaults.standard.bool(forKey: "peariscope.startSharingOnStartup") && !hostSession.isActive {
                do {
                    try await hostSession.start()
                } catch {
                    networkManager.lastError = "Auto-start error: \(error.localizedDescription)"
                }
            }
        }
    }
}
