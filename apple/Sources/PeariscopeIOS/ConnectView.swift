#if os(iOS)
import SwiftUI
import UIKit
import PeariscopeCore
import AVFoundation

// MARK: - Connect View

struct IOSConnectView: View {
    @ObservedObject var networkManager: NetworkManager
    @State private var connectionCode = ""
    @State private var showScanner = false
    @State private var savedHosts: [SavedHost] = SavedHost.loadAll()
    @State private var renamingHost: SavedHost?
    @State private var renameText = ""
    @State private var hostOnlineStatus: [String: Bool] = [:]
    @FocusState private var isCodeFocused: Bool
    @State private var suggestions: [String] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero
                heroSection
                    .padding(.top, 32)

                // Connect input
                VStack(spacing: 0) {
                    seedPhraseInput

                    if !suggestions.isEmpty && isCodeFocused {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.self) { word in
                                    Button {
                                        applySuggestion(word)
                                    } label: {
                                        Text(word)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.pearGreen)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule()
                                                    .fill(Color.pearGreen.opacity(0.12))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.horizontal, 24)

                // Quick actions row
                quickActions
                    .padding(.horizontal, 24)

                // Recent connections
                if !savedHosts.isEmpty {
                    recentSection
                        .padding(.horizontal, 24)
                }

                // Error
                if let error = networkManager.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(error)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 20)

                // Footer
                HStack(spacing: 4) {
                    Text("Powered by")
                    Image("PearLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 9)
                    Link("Pear Runtime", destination: URL(string: "https://pears.com")!)
                }
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .padding(.bottom, 16)
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            savedHosts = SavedHost.loadAll()
            probeHosts()
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingHost != nil },
            set: { if !$0 { renamingHost = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let host = renamingHost, !renameText.isEmpty {
                    SavedHost.rename(code: host.code, newName: renameText)
                    savedHosts = SavedHost.loadAll()
                }
                renamingHost = nil
            }
            Button("Cancel", role: .cancel) { renamingHost = nil }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.pearGlow)
                    .frame(width: 72, height: 72)
                    .blur(radius: 20)
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
            }

            Text("PEARISCOPE")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.primary)

            Text("Connect to a remote desktop")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Seed Phrase Input

    private var seedPhraseInput: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                TextField("Enter seed phrase...", text: $connectionCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14))
                    .focused($isCodeFocused)
                    .submitLabel(.go)
                    .onSubmit { connectToHost(code: connectionCode) }
                    .onChange(of: connectionCode) { updateSuggestions() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemBackground))
            )

            Button {
                connectToHost(code: connectionCode)
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(connectionCode.isEmpty ? Color.gray.opacity(0.3) : Color.pearGreen)
                    )
            }
            .disabled(connectionCode.isEmpty)
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickActionButton(
                icon: "qrcode.viewfinder",
                title: "Scan QR"
            ) {
                showScanner = true
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(networkManager: networkManager, isPresented: $showScanner)
            }

            quickActionButton(
                icon: "doc.on.clipboard",
                title: "Paste"
            ) {
                if let clip = UIPasteboard.general.string, !clip.isEmpty {
                    connectionCode = clip
                }
            }
        }
    }

    private func quickActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.pearGradient)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Section

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(1)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(savedHosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 48)
                    }

                    Button {
                        connectToHost(code: host.code)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.pearGreen.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.pearGreen)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(host.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Circle()
                                        .fill(hostStatusColor(host))
                                        .frame(width: 5, height: 5)
                                }
                                Text(hostTimeAgo(host))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameText = host.name
                            renamingHost = host
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            SavedHost.remove(code: host.code)
                            savedHosts = SavedHost.loadAll()
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
    }

    // MARK: - Helpers

    private func hostStatusColor(_ host: SavedHost) -> Color {
        if let online = hostOnlineStatus[host.code.uppercased()] {
            return online ? .green : Color(.systemGray3)
        }
        let elapsed = Date().timeIntervalSince(host.lastConnected)
        if elapsed < 300 { return .green }
        if elapsed < 3600 { return .yellow }
        if elapsed < 86400 { return .orange }
        return Color(.systemGray3)
    }

    private func hostTimeAgo(_ host: SavedHost) -> String {
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

    private func updateSuggestions() {
        let words = connectionCode.split(separator: " ")
        guard let lastWord = words.last, !lastWord.isEmpty else {
            suggestions = []
            return
        }
        let prefix = String(lastWord).lowercased()
        // Don't show suggestions if word is already complete
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

    private func connectToHost(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        SavedHost.save(code: trimmed)
        savedHosts = SavedHost.loadAll()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await networkManager.connectFromQR(trimmed)
            } catch {
                networkManager.lastError = "Connection failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Saved Hosts

struct SavedHost: Identifiable, Codable {
    var id: String { code }
    let code: String
    let name: String
    let lastConnected: Date

    private static let key = "peariscope.savedHosts"

    static func loadAll() -> [SavedHost] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let hosts = try? JSONDecoder().decode([SavedHost].self, from: data) else {
            return []
        }
        return hosts.sorted { $0.lastConnected > $1.lastConnected }
    }

    static func save(code: String, name: String? = nil) {
        var hosts = loadAll()
        let existingName = hosts.first(where: { $0.code.uppercased() == code.uppercased() })?.name
        hosts.removeAll { $0.code.uppercased() == code.uppercased() }
        let host = SavedHost(
            code: code.uppercased(),
            name: name ?? existingName ?? code.uppercased(),
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
            hosts[i] = SavedHost(code: hosts[i].code, name: newName, lastConnected: hosts[i].lastConnected)
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

// MARK: - QR Scanner

struct QRScannerSheet: View {
    @ObservedObject var networkManager: NetworkManager
    @Binding var isPresented: Bool
    @State private var scannedCode: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Scan QR Code")
                    .font(.title3.bold())
                    .padding(.top)

                Text("Point your camera at the host's QR code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                QRScannerViewRepresentable { code in
                    scannedCode = code
                    Task {
                        do {
                            let displayCode = Self.extractCode(from: code)
                            SavedHost.save(code: displayCode)
                            try await networkManager.connectFromQR(code)
                        } catch {
                            networkManager.lastError = "Connection failed: \(error.localizedDescription)"
                        }
                        isPresented = false
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.pearGreen.opacity(0.3), lineWidth: 2)
                )
                .padding(.horizontal, 24)

                if let scannedCode {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.pearGreen)
                        Text("Connecting: \(scannedCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    static func extractCode(from scanned: String) -> String {
        if scanned.hasPrefix("peariscope://relay?"),
           let url = URL(string: scanned),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            return code
        }
        return scanned
    }
}

// MARK: - AVFoundation QR Scanner

struct QRScannerViewRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showFallback()
            return
        }

        guard session.canAddInput(input) else {
            showFallback()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showFallback()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        captureSession = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func showFallback() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = metadata.stringValue else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasScanned else { return }
            self.hasScanned = true
            self.captureSession?.stopRunning()
            self.onCodeScanned?(code)
        }
    }
}
#endif
