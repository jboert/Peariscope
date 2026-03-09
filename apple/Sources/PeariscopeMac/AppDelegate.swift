import SwiftUI
import AppKit
import Combine
import PeariscopeCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusCancellables = Set<AnyCancellable>()
    private var viewerWindow: NSWindow?

    let networkManager = NetworkManager()
    let hostSession: HostSession

    override init() {
        let nm = networkManager
        hostSession = HostSession(networkManager: nm)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSLog("[app] applicationDidFinishLaunching — menu bar mode")

        // Update the menu bar icon to show the Peariscope logo with status dot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setupStatusItemIcon()
            self?.observeStatus()
        }

        startRuntime()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
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
            }
        )

        let hostingView = NSHostingView(rootView: viewerContent)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
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
