import SwiftUI
import PeariscopeCore

@main
struct PeariscopeApp: App {
    @StateObject private var networkManager = NetworkManager()
    @StateObject private var hostSession: HostSession
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let nm = NetworkManager()
        _networkManager = StateObject(wrappedValue: nm)
        let hs = HostSession(networkManager: nm)
        _hostSession = StateObject(wrappedValue: hs)
        PinApprovalPanel.shared.observe(hostSession: hs)
    }

    var body: some Scene {
        WindowGroup("Peariscope") {
            ContentView(networkManager: networkManager, hostSession: hostSession)
                .tint(.pearGreen)
                .onAppear {
                    appDelegate.hostSession = hostSession
                    appDelegate.networkManager = networkManager
                }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject var hostSession: HostSession
    @State private var mode: AppMode = UserDefaults.standard.bool(forKey: "peariscope.startSharingOnStartup") ? .hosting : .idle

    enum AppMode: Hashable {
        case idle, hosting, viewing, settings
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text("Peariscope")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    navItem("Home", icon: "house.fill", mode: .idle)
                    navItem("Host", icon: "antenna.radiowaves.left.and.right", mode: .hosting)
                    navItem("Connect", icon: "display", mode: .viewing)
                    navItem("Settings", icon: "gearshape", mode: .settings)
                }
                .padding(.horizontal, 8)

                Spacer()

                if !networkManager.connectedPeers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PEERS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .tracking(1)
                        ForEach(networkManager.connectedPeers) { peer in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.pearGreen)
                                    .frame(width: 6, height: 6)
                                    .shadow(color: .pearGreen.opacity(0.5), radius: 3)
                                Text(String(peer.id.prefix(8)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
            .frame(width: 140)
            .background(.ultraThinMaterial)

            Divider()

            // Detail
            Group {
                switch mode {
                case .idle:
                    IdleView(networkManager: networkManager, mode: $mode)
                case .hosting:
                    HostView(networkManager: networkManager, hostSession: hostSession)
                case .viewing:
                    ViewerView(networkManager: networkManager)
                case .settings:
                    SettingsView(networkManager: networkManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 360)
        .task {
            do {
                try await networkManager.startRuntime()
            } catch {
                networkManager.lastError = "Failed to start Pear runtime: \(error.localizedDescription)"
            }
        }
    }

    private func navItem(_ title: String, icon: String, mode: AppMode) -> some View {
        let selected = self.mode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.mode = mode
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(selected ? .pearGreen : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.pearGreenDim : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}
