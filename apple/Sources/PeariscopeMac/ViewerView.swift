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

// MARK: - Viewer Window (standalone)

struct ViewerWindowView: View {
    @ObservedObject var networkManager: NetworkManager
    @StateObject private var viewerSession: ViewerSession
    let onClose: () -> Void
    let onVideoSizeChanged: ((CGSize) -> Void)?
    let onDisconnected: (() -> Void)?

    @State private var connectionCode = ""
    @State private var savedHosts: [MacSavedHost] = MacSavedHost.loadAll()
    @State private var renamingHost: MacSavedHost?
    @State private var renameText = ""
    @State private var hoveredHostId: String?
    @State private var hostOnlineStatus: [String: Bool] = [:]
    @State private var isConnecting = false
    @State private var suggestions: [String] = []

    init(networkManager: NetworkManager, onClose: @escaping () -> Void, onVideoSizeChanged: ((CGSize) -> Void)? = nil, onDisconnected: (() -> Void)? = nil) {
        self.networkManager = networkManager
        self.onClose = onClose
        self.onVideoSizeChanged = onVideoSizeChanged
        self.onDisconnected = onDisconnected
        _viewerSession = StateObject(wrappedValue: ViewerSession(networkManager: networkManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewerSession.isActive {
                viewerActiveView
            } else if isConnecting {
                connectingView
            } else {
                connectView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewerSession.isActive)
        .animation(.easeInOut(duration: 0.2), value: isConnecting)
        .tint(.pearGreen)
        .onChange(of: viewerSession.videoSize) {
            if let size = viewerSession.videoSize {
                onVideoSizeChanged?(size)
            }
        }
        .onChange(of: viewerSession.isActive) {
            if viewerSession.isActive {
                isConnecting = false
            } else {
                onDisconnected?()
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

    // MARK: - Connecting

    private var connectingView: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let squish = sin(t * 2 * .pi / 1.4) // -1→1 cycle over 1.4s
            let scaleX = 1.0 + 0.08 * squish
            let scaleY = 1.0 - 0.08 * squish
            let pulse = (1 + cos(t * 2 * .pi / 2.0)) / 2
            let bounce = 1.0 + 0.03 * sin(t * 2 * .pi / 0.7)

            VStack(spacing: 20) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(Color.pearGreen.opacity(0.15), lineWidth: 2)
                        .frame(width: 100, height: 100)
                        .scaleEffect(1.0 + 0.4 * (1 - pulse))
                        .opacity(pulse * 0.5)

                    Circle()
                        .stroke(Color.pearGreen.opacity(0.08), lineWidth: 1.5)
                        .frame(width: 130, height: 130)
                        .scaleEffect(1.0 + 0.3 * pulse)
                        .opacity((1 - pulse) * 0.4)

                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .scaleEffect(x: scaleX * bounce, y: scaleY * bounce)
                }
                .frame(height: 130)

                VStack(spacing: 6) {
                    Text("Connecting...")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Looking for peer on the network")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Button {
                    isConnecting = false
                    viewerSession.disconnect()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            ZStack {
                MetalViewRepresentable(viewerSession: viewerSession)

                if viewerSession.videoSize == nil {
                    // Waiting for first frame
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let squish = sin(t * 2 * .pi / 1.4)
                        let scaleX = 1.0 + 0.08 * squish
                        let scaleY = 1.0 - 0.08 * squish
                        let pulse = (1 + cos(t * 2 * .pi / 2.0)) / 2
                        let bounce = 1.0 + 0.03 * sin(t * 2 * .pi / 0.7)

                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .stroke(Color.pearGreen.opacity(0.15), lineWidth: 2)
                                    .frame(width: 90, height: 90)
                                    .scaleEffect(1.0 + 0.4 * (1 - pulse))
                                    .opacity(pulse * 0.5)

                                Image("AppLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 48, height: 48)
                                    .scaleEffect(x: scaleX * bounce, y: scaleY * bounce)
                            }

                            Text("Waiting for video...")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Connect Screen

    private var connectView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.pearGradient)

                Text("Connect to Remote Desktop")
                    .font(.system(size: 16, weight: .semibold))

                // Seed phrase input
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("Enter seed phrase...", text: $connectionCode)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .onSubmit { connectToCode(connectionCode) }
                            .onChange(of: connectionCode) { updateSuggestions() }

                        Button {
                            connectToCode(connectionCode)
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(connectionCode.isEmpty ? Color.gray.opacity(0.2) : Color.pearGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(connectionCode.isEmpty)
                    }

                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(suggestions, id: \.self) { word in
                                    Button {
                                        applySuggestion(word)
                                    } label: {
                                        Text(word)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.pearGreen)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule()
                                                    .fill(Color.pearGreen.opacity(0.1))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, 40)
            }

            // Recent connections
            if !savedHosts.isEmpty {
                VStack(spacing: 4) {
                    HStack {
                        Text("RECENT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, 44)
                    .padding(.top, 20)

                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(savedHosts) { host in
                                savedHostRow(host)
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                    .frame(maxHeight: 200)
                }
            }

            Spacer()
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

    private func updateSuggestions() {
        let words = connectionCode.split(separator: " ")
        guard let lastWord = words.last, !lastWord.isEmpty else {
            suggestions = []
            return
        }
        let prefix = String(lastWord).lowercased()
        if BIP39.isValidWord(prefix) && connectionCode.hasSuffix(" ") {
            suggestions = []
            return
        }
        suggestions = Array(BIP39.completions(for: prefix).prefix(8))
    }

    private func applySuggestion(_ word: String) {
        var words = connectionCode.split(separator: " ").map(String.init)
        if !words.isEmpty {
            words[words.count - 1] = word
        } else {
            words.append(word)
        }
        connectionCode = words.joined(separator: " ") + " "
        suggestions = []
    }

    private func connectToCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        MacSavedHost.save(code: trimmed)
        savedHosts = MacSavedHost.loadAll()
        isConnecting = true
        Task {
            do {
                try await viewerSession.connect(code: trimmed)
            } catch {
                isConnecting = false
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
