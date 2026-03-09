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
    @State private var showSeedPhraseEntry = false
    @State private var savedHosts: [SavedHost] = SavedHost.loadAll()
    @State private var renamingHost: SavedHost?
    @State private var renameText = ""
    /// DHT lookup results: code -> online status. Nil = pending.
    @State private var hostOnlineStatus: [String: Bool] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.pearGlow)
                            .frame(width: 44, height: 44)
                            .blur(radius: 12)
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Peariscope")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Peer-to-peer remote desktop")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // Quick actions
                HStack(spacing: 10) {
                    quickActionButton(
                        title: "Scan QR",
                        icon: "qrcode.viewfinder"
                    ) {
                        showScanner = true
                    }
                    .sheet(isPresented: $showScanner) {
                        QRScannerSheet(networkManager: networkManager, isPresented: $showScanner)
                    }

                    quickActionButton(
                        title: "Enter Seed Phrase",
                        icon: "keyboard"
                    ) {
                        showSeedPhraseEntry = true
                    }
                }
                .padding(.horizontal, 20)

                // Saved hosts
                if !savedHosts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RECENT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .tracking(1.5)
                            .padding(.horizontal, 22)

                        ForEach(savedHosts) { host in
                            Button {
                                connectToHost(code: host.code)
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.pearGreenDim)
                                            .frame(width: 34, height: 34)
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.pearGreen)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 5) {
                                            Text(host.name)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(.primary)
                                            Circle()
                                                .fill(hostStatusColor(host))
                                                .frame(width: 6, height: 6)
                                                .shadow(color: hostStatusColor(host).opacity(0.6), radius: 2)
                                        }
                                        Text(hostTimeAgo(host))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.quaternary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.secondarySystemBackground))
                                )
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
                        .padding(.horizontal, 20)
                    }
                }

                if let error = networkManager.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Capsule())
                }

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
                .padding(.top, 2)
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
        .alert("Enter Seed Phrase", isPresented: $showSeedPhraseEntry) {
            TextField("12 words", text: $connectionCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect") {
                connectToHost(code: connectionCode)
                connectionCode = ""
            }
            Button("Cancel", role: .cancel) {
                connectionCode = ""
            }
        } message: {
            Text("Enter the 12-word seed phrase from the host")
        }
    }

    private func quickActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.pearGreenDim)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.pearGreen)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func hostStatusColor(_ host: SavedHost) -> Color {
        // Use DHT result if available
        if let online = hostOnlineStatus[host.code.uppercased()] {
            return online ? .green : Color(.systemGray3)
        }
        // Fallback to time-based while DHT lookup is pending
        let elapsed = Date().timeIntervalSince(host.lastConnected)
        if elapsed < 300 { return .green }
        if elapsed < 3600 { return .yellow }
        if elapsed < 86400 { return .orange }
        return Color(.systemGray3)
    }

    private func hostTimeAgo(_ host: SavedHost) -> String {
        // Show online/offline if DHT result available
        if let online = hostOnlineStatus[host.code.uppercased()] {
            if online { return "Online" }
            let elapsed = Date().timeIntervalSince(host.lastConnected)
            if elapsed < 60 { return "Offline · Just now" }
            if elapsed < 3600 { return "Offline · \(Int(elapsed / 60))m ago" }
            if elapsed < 86400 { return "Offline · \(Int(elapsed / 3600))h ago" }
            let days = Int(elapsed / 86400)
            return days == 1 ? "Offline · Yesterday" : "Offline · \(days)d ago"
        }
        // Time-based fallback while probing
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
            // Ensure worklet is running for DHT lookups
            if !networkManager.isWorkletAlive {
                try? await networkManager.startRuntime()
            }
            for host in savedHosts {
                networkManager.lookupPeer(code: host.code)
            }
        }
    }

    private func connectToHost(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        SavedHost.save(code: trimmed)
        savedHosts = SavedHost.loadAll()
        // [4] Haptic on connect
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
        // Preserve existing custom name if no new name provided
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
                            // Save the connection code for quick reconnect
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
