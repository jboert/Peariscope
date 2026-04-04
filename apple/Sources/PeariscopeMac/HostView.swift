import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import PeariscopeCore

// MARK: - Host Idle (Not Sharing)

struct HostIdleView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject var hostSession: HostSession
    @State private var glowPhase = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)

            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text("Not Sharing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.04))
            )

            // Display picker
            if hostSession.availableDisplays.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Picker("", selection: $hostSession.selectedDisplay) {
                        ForEach(hostSession.availableDisplays, id: \.displayID) { display in
                            Text("\(display.width)x\(display.height)")
                                .tag(Optional(display))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 140)
                }
            }

            // Start button
            Button {
                Task {
                    do {
                        try await hostSession.start()
                    } catch {
                        networkManager.lastError = "Host error: \(error.localizedDescription)"
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .medium))
                    Text("Start Sharing")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.pearGreen)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            Spacer().frame(height: 8)
        }
        .task {
            try? await hostSession.refreshDisplays()
        }
    }
}

// MARK: - Host Active (Sharing)

struct HostActiveView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject var hostSession: HostSession
    @State private var codeVisible = false

    var body: some View {
        VStack(spacing: 10) {
                // Live status badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.pearGreen)
                        .frame(width: 8, height: 8)
                        .shadow(color: .pearGreen.opacity(0.6), radius: 4)
                    Text("SHARING")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundColor(.pearGreen)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.pearGreenDim)
                )
                .padding(.top, 10)

                // Stats row
                HStack(spacing: 0) {
                    statCell(value: "\(Int(hostSession.fps))", label: "FPS")
                    Divider().frame(height: 24)
                    statCell(value: String(format: "%.1fM", Double(hostSession.bitrate) / 1_000_000.0), label: "BPS")
                    Divider().frame(height: 24)
                    statCell(value: "\(networkManager.connectedPeers.count)", label: "VIEWERS")
                }
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, 16)

                // Connection code
                if let code = networkManager.connectionCode {
                    connectionCodeCard(code: code)
                        .padding(.horizontal, 16)
                }

                // Codec & display info
                HStack(spacing: 6) {
                    Text(hostSession.useH265 ? "H.265" : "H.264")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(hostSession.useH265 ? Color.pearGreenDim : Color.gray.opacity(0.1))
                        .foregroundColor(hostSession.useH265 ? .pearGreen : .secondary)
                        .clipShape(Capsule())

                    if let display = hostSession.selectedDisplay {
                        Text("\(display.width)x\(display.height)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button(hostSession.useH265 ? "H.264" : "H.265") {
                        hostSession.switchCodec(toH265: !hostSession.useH265)
                    }
                    .font(.system(size: 9))
                    .controlSize(.mini)
                    .disabled(!H265Encoder.isSupported && !hostSession.useH265)
                }
                .padding(.horizontal, 16)

                // Screen Recording permission warning
                if !hostSession.hasScreenRecordingPermission {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 10))
                        Text("Screen Recording denied")
                            .font(.system(size: 10))
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                            .font(.system(size: 10))
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.mini)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 16)
                }

                // Accessibility warning
                if !hostSession.hasAccessibilityPermission {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                        Text("Accessibility required")
                            .font(.system(size: 10))
                        Spacer()
                        Button("Grant") { hostSession.requestAccessibility() }
                            .font(.system(size: 10))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 16)
                }

                // PIN verification handled by floating panel (AppDelegate)

                // Stop button
                Button(role: .destructive) {
                    Task { try? await hostSession.stop() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop Sharing")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .animation(.easeInOut(duration: 0.2), value: hostSession.pendingPeerPin != nil)
    }

    // MARK: - Components

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.quaternary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func connectionCodeCard(code: String) -> some View {
        let qrPayload = buildQRPayload(
            code: code,
            host: networkManager.relayHost,
            port: networkManager.relayPort
        )

        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // QR code
                if codeVisible, let qrImage = generateQRCode(from: qrPayload) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .padding(6)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.04))
                            .frame(width: 92, height: 92)
                        Image(systemName: "qrcode")
                            .font(.system(size: 28))
                            .foregroundStyle(.quaternary)
                    }
                }

                // Words
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connection Code")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)

                    if codeVisible {
                        let words = code.split(separator: " ")
                        LazyVGrid(columns: [
                            GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 2) {
                            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                                HStack(spacing: 1) {
                                    Text("\(i + 1).")
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(.quaternary)
                                    Text(word)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.pearGreen)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                    } else {
                        Text("Tap eye to reveal")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 0)

                    // Action buttons
                    HStack(spacing: 6) {
                        Button {
                            codeVisible.toggle()
                        } label: {
                            Image(systemName: codeVisible ? "eye.slash" : "eye")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button {
                            Task { try? await networkManager.regenerateCode() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func pinApprovalCard(pin: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("Peer Connecting")
                    .font(.system(size: 12, weight: .semibold))
            }

            if let fingerprint = hostSession.pendingPeerFingerprint {
                Text(fingerprint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(pin)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(.pearGreen)

            Text("Verify this PIN matches the viewer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    hostSession.respondToPeer(accepted: false)
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                Button {
                    hostSession.respondToPeer(accepted: true)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Floating PIN Approval Panel

struct PinApprovalPanelView: View {
    @ObservedObject var hostSession: HostSession
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                Text("Peer Wants to Connect")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            if let fingerprint = hostSession.pendingPeerFingerprint {
                HStack {
                    Text(fingerprint)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    hostSession.respondToPeer(accepted: false)
                    onDismiss()
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)

                Button {
                    hostSession.respondToPeer(accepted: true)
                    onDismiss()
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pearGreen)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Utilities

func buildQRPayload(code: String, host: String?, port: UInt32?) -> String {
    guard let host, let port, port > 0 else { return code }
    return "peariscope://relay?code=\(code)&host=\(host)&port=\(port)"
}

func generateQRCode(from string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let ciImage = filter.outputImage else { return nil }
    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}
