import SwiftUI
import AppKit
import Combine
import PeariscopeCore

// MARK: - Floating PIN Approval Panel

/// Shows a small floating panel in the top-right corner when a peer is connecting
/// and the main window is closed. Allows approve/reject without opening the full app.
/// Observes HostSession.pendingPeerPin via Combine — works even when the main window is closed.
@MainActor
final class PinApprovalPanel {
    static let shared = PinApprovalPanel()
    private var panel: NSPanel?
    private weak var hostSession: HostSession?
    private var cancellable: AnyCancellable?

    func observe(hostSession: HostSession) {
        self.hostSession = hostSession
        cancellable = hostSession.$pendingPeerPin
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pin in
                guard let self else { return }
                if let pin {
                    // Show floating panel if no main window is visible
                    let hasVisibleMain = NSApplication.shared.windows.contains {
                        ($0.canBecomeMain || $0.title == "Peariscope") && $0.isVisible
                    }
                    if !hasVisibleMain {
                        self.show(pin: pin, hostSession: hostSession)
                    }
                } else {
                    self.dismiss()
                }
            }
    }

    private func show(pin: String, hostSession: HostSession) {
        dismiss() // Close any existing panel

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 180),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Peariscope"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        let hostingView = NSHostingView(rootView: PinApprovalContent(
            pin: pin,
            onApprove: { [weak self] in
                self?.hostSession?.respondToPeer(accepted: true)
                self?.dismiss()
            },
            onReject: { [weak self] in
                self?.hostSession?.respondToPeer(accepted: false)
                self?.dismiss()
            }
        ))
        panel.contentView = hostingView

        // Position in top-right corner of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 280 - 16
            let y = screenFrame.maxY - 180 - 16
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

struct PinApprovalContent: View {
    let pin: String
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.checkmark")
                    .foregroundColor(.orange)
                Text("Peer Connecting")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("Verify PIN with viewer:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(pin)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(.pearGreen)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }

                Button {
                    onApprove()
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
    }
}
