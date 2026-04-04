import SwiftUI
import PeariscopeCore

// MARK: - Popover Root

struct PopoverContentView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject var hostSession: HostSession
    let onOpenViewer: () -> Void
    let onQuit: () -> Void

    @State private var page: Page = .main

    enum Page: Hashable {
        case main, settings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch page {
                case .main:
                    mainPage
                case .settings:
                    SettingsView(networkManager: networkManager, onBack: { page = .main })
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.15), value: page)

            Divider()
            footer
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)

            Text("PEARISCOPE")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.primary)

            Spacer()

            if page == .settings {
                Button {
                    page = .main
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    page = .settings
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Main Page

    private var mainPage: some View {
        VStack(spacing: 0) {
            if hostSession.isActive {
                HostActiveView(networkManager: networkManager, hostSession: hostSession)
            } else {
                HostIdleView(networkManager: networkManager, hostSession: hostSession)
            }

            // OTA update status
            otaStatusBanner

            if let error = networkManager.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.06))
            }
        }
    }

    // MARK: - OTA Update Banner

    @ViewBuilder
    private var otaStatusBanner: some View {
        switch networkManager.otaStatus {
        case .idle:
            EmptyView()
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading update...")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.blue)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.blue.opacity(0.06))
        case .ready(let version):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10))
                Text("Update v\(version) ready — restart to apply")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.06))
        case .applied(let version):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                Text("Updated to v\(version)")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.06))
        case .failed(let error):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("Update failed: \(error)")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.06))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton(icon: "display", title: "Connect", action: onOpenViewer)
            Divider().frame(height: 20)
            footerButton(icon: "power", title: "Quit", action: onQuit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func footerButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.001))
        .onTapGesture { action() }
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
