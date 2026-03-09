import SwiftUI
import AppKit
import PeariscopeCore

// MARK: - App Lifecycle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    weak var hostSession: HostSession?
    weak var networkManager: NetworkManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — writing to a broken BareKit IPC pipe sends SIGPIPE,
        // which kills the app instantly. Ignoring lets write() return an error.
        signal(SIGPIPE, SIG_IGN)
        NSLog("[app] applicationDidFinishLaunching")

        let startMinimized = UserDefaults.standard.bool(forKey: "peariscope.startMinimized")
        if startMinimized {
            // Hide all windows — app lives in menu bar tray until opened
            // Delay to let SwiftUI finish creating windows first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for window in NSApplication.shared.windows {
                    window.close()
                }
            }
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        setupStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    // MARK: - NSStatusItem Menu Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Peariscope")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    fileprivate func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        if let hs = hostSession {
            if hs.isActive {
                let peers = networkManager?.connectedPeers.count ?? 0
                if peers > 0 {
                    let item = NSMenuItem(title: "Sharing with \(peers) peer(s)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(title: "Available to share", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem(title: "Stop Sharing", action: #selector(stopSharing), keyEquivalent: ""))

                if let pin = hs.pendingPeerPin {
                    menu.addItem(NSMenuItem.separator())
                    let pinItem = NSMenuItem(title: "PIN: \(pin)", action: nil, keyEquivalent: "")
                    pinItem.isEnabled = false
                    menu.addItem(pinItem)
                    menu.addItem(NSMenuItem(title: "Approve Peer", action: #selector(approvePeer), keyEquivalent: ""))
                    menu.addItem(NSMenuItem(title: "Reject Peer", action: #selector(rejectPeer), keyEquivalent: ""))
                }
            } else {
                menu.addItem(NSMenuItem(title: "Start Sharing", action: #selector(startSharing), keyEquivalent: ""))
                menu.addItem(NSMenuItem.separator())
                let item = NSMenuItem(title: "Not sharing", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindowAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
    }

    @objc private func startSharing() {
        guard let hs = hostSession else { return }
        Task { @MainActor in try? await hs.start() }
    }

    @objc private func stopSharing() {
        guard let hs = hostSession else { return }
        Task { @MainActor in try? await hs.stop() }
    }

    @objc private func approvePeer() {
        hostSession?.respondToPeer(accepted: true)
    }

    @objc private func rejectPeer() {
        hostSession?.respondToPeer(accepted: false)
    }

    @objc private func showWindowAction() {
        showMainWindow()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }
}

/// Show the main Peariscope window, creating it if needed
func showMainWindow() {
    NSApplication.shared.activate(ignoringOtherApps: true)

    // Try to find and show an existing window
    for window in NSApplication.shared.windows {
        // Skip menu bar extra windows and other non-content windows
        if window.canBecomeMain || window.title == "Peariscope" {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
    }

    // No window found — use the standard macOS "New Window" action
    // This triggers SwiftUI's WindowGroup to create a new window
    if NSApp.responds(to: #selector(NSApplication.sendAction(_:to:from:))) {
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        // Activate again after creating
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
