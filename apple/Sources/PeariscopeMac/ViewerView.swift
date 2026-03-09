import SwiftUI
import MetalKit
import AppKit
import PeariscopeCore

// MARK: - Saved Hosts (Recent Connections)

struct MacSavedHost: Identifiable, Codable {
    var id: String { code }
    let code: String
    let name: String
    let lastConnected: Date

    private static let key = "peariscope.savedHosts"

    static func loadAll() -> [MacSavedHost] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let hosts = try? JSONDecoder().decode([MacSavedHost].self, from: data) else {
            return []
        }
        return hosts.sorted { $0.lastConnected > $1.lastConnected }
    }

    static func save(code: String, name: String? = nil) {
        var hosts = loadAll()
        let existingName = hosts.first(where: { $0.code.uppercased() == code.uppercased() })?.name
        hosts.removeAll { $0.code.uppercased() == code.uppercased() }
        let words = code.trimmingCharacters(in: .whitespaces).split(separator: " ")
        let shortCode = words.prefix(2).joined(separator: " ").uppercased()
        let host = MacSavedHost(
            code: code.uppercased(),
            name: name ?? existingName ?? "Desktop (\(shortCode)...)",
            lastConnected: Date()
        )
        hosts.insert(host, at: 0)
        if hosts.count > 10 { hosts = Array(hosts.prefix(10)) }
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func rename(code: String, newName: String) {
        var hosts = loadAll()
        if let i = hosts.firstIndex(where: { $0.code.uppercased() == code.uppercased() }) {
            hosts[i] = MacSavedHost(code: hosts[i].code, name: newName, lastConnected: hosts[i].lastConnected)
            if let data = try? JSONEncoder().encode(hosts) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func remove(code: String) {
        var hosts = loadAll()
        hosts.removeAll { $0.code.uppercased() == code.uppercased() }
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Viewer

struct ViewerView: View {
    @ObservedObject var networkManager: NetworkManager
    @StateObject private var viewerSession: ViewerSession
    @State private var connectionCode = ""
    @State private var savedHosts: [MacSavedHost] = MacSavedHost.loadAll()
    @State private var renamingHost: MacSavedHost?
    @State private var renameText = ""
    @State private var hoveredHostId: String?
    @State private var hostOnlineStatus: [String: Bool] = [:]

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        _viewerSession = StateObject(wrappedValue: ViewerSession(networkManager: networkManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewerSession.isActive {
                viewerActiveView
            } else {
                connectView
            }
        }
        .alert("Rename Connection", isPresented: Binding(
            get: { renamingHost != nil },
            set: { if !$0 { renamingHost = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let host = renamingHost, !renameText.isEmpty {
                    MacSavedHost.rename(code: host.code, newName: renameText)
                    savedHosts = MacSavedHost.loadAll()
                }
                renamingHost = nil
            }
            Button("Cancel", role: .cancel) { renamingHost = nil }
        }
    }

    // MARK: - Active Viewer

    private var viewerActiveView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.pearGreen)
                        .frame(width: 5, height: 5)
                        .shadow(color: .pearGreen.opacity(0.5), radius: 2)
                    Text("\(Int(viewerSession.fps))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("FPS")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                if viewerSession.latencyMs > 0 {
                    Text("\(Int(viewerSession.latencyMs))ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(viewerSession.currentCodec)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.pearGreenDim)
                    .foregroundColor(.pearGreen)
                    .clipShape(Capsule())

                Divider().frame(height: 14)

                Button {
                    viewerSession.toggleInputCapture()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewerSession.isCapturingInput ? "keyboard.fill" : "keyboard")
                            .font(.system(size: 11))
                        Text(viewerSession.isCapturingInput ? "ON" : "OFF")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(viewerSession.isCapturingInput ? .pearGreen : .secondary)
                }
                .help("Toggle input capture (Cmd+Shift+I)")
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Spacer()

                Button(role: .destructive) {
                    viewerSession.disconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)

            MetalViewRepresentable(viewerSession: viewerSession)
        }
    }

    // MARK: - Connect Screen

    private var connectView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.and.arrow.down")
                        .font(.system(size: 18, weight: .thin))
                        .foregroundStyle(.pearGradient)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect to Remote Desktop")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Enter a seed phrase or select a recent connection")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Seed phrase input
                HStack(spacing: 8) {
                    TextField("Enter seed phrase...", text: $connectionCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .onSubmit { connectToCode(connectionCode) }

                    Button {
                        connectToCode(connectionCode)
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(connectionCode.isEmpty ? Color.gray.opacity(0.2) : Color.pearGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(connectionCode.isEmpty)
                }
                .padding(.horizontal, 20)

                // Recent connections
                if !savedHosts.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("RECENT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                    VStack(spacing: 3) {
                        ForEach(savedHosts) { host in
                            savedHostRow(host)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer(minLength: 12)
            }
        }
        .onAppear {
            savedHosts = MacSavedHost.loadAll()
            probeHosts()
        }
    }

    private func savedHostRow(_ host: MacSavedHost) -> some View {
        Button {
            connectToCode(host.code)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.pearGreen.opacity(0.7).gradient)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(host.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Circle()
                            .fill(hostStatusColor(host))
                            .frame(width: 6, height: 6)
                            .shadow(color: hostStatusColor(host).opacity(0.6), radius: 2)
                    }
                    Text(hostTimeAgo(host))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(hoveredHostId == host.id ? 0.08 : 0.03), radius: hoveredHostId == host.id ? 8 : 4, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(hoveredHostId == host.id ? 0.1 : 0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredHostId = isHovered ? host.id : nil
            }
        }
        .contextMenu {
            Button {
                renameText = host.name
                renamingHost = host
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                MacSavedHost.remove(code: host.code)
                savedHosts = MacSavedHost.loadAll()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func connectToCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        MacSavedHost.save(code: trimmed)
        savedHosts = MacSavedHost.loadAll()
        Task {
            do {
                try await viewerSession.connect(code: trimmed)
            } catch {
                networkManager.lastError = "Connect error: \(error.localizedDescription)"
            }
        }
    }

    private func hostStatusColor(_ host: MacSavedHost) -> Color {
        if let online = hostOnlineStatus[host.code.uppercased()] {
            return online ? .green : Color.gray.opacity(0.5)
        }
        let elapsed = Date().timeIntervalSince(host.lastConnected)
        if elapsed < 300 { return .green }
        if elapsed < 3600 { return .yellow }
        if elapsed < 86400 { return .orange }
        return Color.gray.opacity(0.5)
    }

    private func hostTimeAgo(_ host: MacSavedHost) -> String {
        if let online = hostOnlineStatus[host.code.uppercased()] {
            if online { return "Online" }
            let elapsed = Date().timeIntervalSince(host.lastConnected)
            if elapsed < 60 { return "Offline · Just now" }
            if elapsed < 3600 { return "Offline · \(Int(elapsed / 60))m ago" }
            if elapsed < 86400 { return "Offline · \(Int(elapsed / 3600))h ago" }
            let days = Int(elapsed / 86400)
            return days == 1 ? "Offline · Yesterday" : "Offline · \(days)d ago"
        }
        let elapsed = Date().timeIntervalSince(host.lastConnected)
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        let days = Int(elapsed / 86400)
        return days == 1 ? "Yesterday" : "\(days)d ago"
    }

    private func probeHosts() {
        guard !savedHosts.isEmpty else { return }
        networkManager.onLookupResult = { code, online in
            DispatchQueue.main.async {
                hostOnlineStatus[code.uppercased()] = online
            }
        }
        Task {
            if !networkManager.isWorkletAlive {
                try? await networkManager.startRuntime()
            }
            for host in savedHosts {
                networkManager.lookupPeer(code: host.code)
            }
        }
    }
}

// MARK: - Metal View

struct MetalViewRepresentable: NSViewRepresentable {
    let viewerSession: ViewerSession

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        viewerSession.setup(mtkView: mtkView)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
