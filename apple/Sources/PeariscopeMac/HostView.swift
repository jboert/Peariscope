import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import PeariscopeCore

// MARK: - Host View

struct HostView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject var hostSession: HostSession
    @State private var codeVisible = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if hostSession.isActive {
                    activeHostView
                } else {
                    idleHostView
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: Active hosting

    private var activeHostView: some View {
        VStack(spacing: 12) {
            // Live indicator + stats on same row
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.pearGreen)
                        .frame(width: 7, height: 7)
                        .shadow(color: .pearGreen.opacity(0.6), radius: 3)
                    Text("Live")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 20)

                statPill(icon: "speedometer", value: "\(Int(hostSession.fps))", label: "FPS")
                Divider().frame(height: 20)
                statPill(icon: "arrow.up.arrow.down", value: String(format: "%.1fM", Double(hostSession.bitrate) / 1_000_000.0), label: "Bitrate")
                Divider().frame(height: 20)
                statPill(icon: "person.2.fill", value: "\(networkManager.connectedPeers.count)", label: "Viewers")
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

            if let code = networkManager.connectionCode {
                let qrPayload = buildQRPayload(
                    code: code,
                    host: networkManager.relayHost,
                    port: networkManager.relayPort
                )

                // QR + words side by side
                HStack(alignment: .top, spacing: 14) {
                    if let qrImage = generateQRCode(from: qrPayload) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .padding(8)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan to connect")
                            .font(.system(size: 10))
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
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.quaternary)
                                        Text(word)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.pearGreen)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .textSelection(.enabled)
                        }

                        HStack(spacing: 6) {
                            Button {
                                codeVisible.toggle()
                            } label: {
                                Image(systemName: codeVisible ? "eye.slash" : "eye")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help(codeVisible ? "Hide Words" : "Show Words")

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Copy Code")

                            Button {
                                Task { try? await networkManager.regenerateCode() }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("New Code")
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }

            // Controls row
            HStack(spacing: 8) {
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

                // Display switcher inline
                if hostSession.availableDisplays.count > 1 {
                    Divider().frame(height: 14)
                    ForEach(hostSession.availableDisplays, id: \.displayID) { display in
                        let active = display.displayID == hostSession.selectedDisplay?.displayID
                        Button {
                            Task { try? await hostSession.switchDisplay(to: display) }
                        } label: {
                            Text("\(display.width)x\(display.height)")
                                .font(.system(size: 9, weight: active ? .semibold : .regular, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(active ? Color.pearGreen : Color.primary.opacity(0.05))
                                .foregroundColor(active ? .white : .secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button(hostSession.useH265 ? "H.264" : "H.265") {
                    hostSession.switchCodec(toH265: !hostSession.useH265)
                }
                .font(.system(size: 9))
                .controlSize(.mini)
                .disabled(!H265Encoder.isSupported && !hostSession.useH265)

                Toggle("Clipboard", isOn: $hostSession.clipboardEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 9))
            }

            if !hostSession.hasAccessibilityPermission {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                    Text("Accessibility required for remote input")
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
            }

            // PIN verification — compact horizontal layout
            if let pin = hostSession.pendingPeerPin {
                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "person.badge.shield.checkmark")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text("Peer Connecting")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        if let fingerprint = hostSession.pendingPeerFingerprint {
                            Text("Fingerprint: \(fingerprint)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("Verify PIN with viewer")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Text(pin)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(.pearGreen)

                    Spacer()

                    VStack(spacing: 6) {
                        Button {
                            hostSession.respondToPeer(accepted: true)
                        } label: {
                            Label("Approve", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            hostSession.respondToPeer(accepted: false)
                        } label: {
                            Label("Reject", systemImage: "xmark.circle")
                        }
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

            Button(role: .destructive) {
                Task { try? await hostSession.stop() }
            } label: {
                Label("Stop Sharing", systemImage: "stop.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)
        }
    }

    // MARK: Idle hosting

    private var idleHostView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.pearGradient)

            VStack(spacing: 4) {
                Text("Share This Screen")
                    .font(.system(size: 16, weight: .semibold))
                Text("Share your screen with other devices")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if !hostSession.availableDisplays.isEmpty {
                Picker("Display", selection: $hostSession.selectedDisplay) {
                    ForEach(hostSession.availableDisplays, id: \.displayID) { display in
                        Text("\(display.width)x\(display.height)")
                            .tag(Optional(display))
                    }
                }
                .frame(width: 160)
                .controlSize(.small)
            }

            Button {
                Task {
                    do {
                        try await hostSession.start()
                    } catch {
                        networkManager.lastError = "Host error: \(error.localizedDescription)"
                    }
                }
            } label: {
                Label("Start Sharing", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer()
        }
        .task {
            try? await hostSession.refreshDisplays()
            // Auto-start sharing if enabled in settings
            if UserDefaults.standard.bool(forKey: "peariscope.startSharingOnStartup") && !hostSession.isActive {
                do {
                    try await hostSession.start()
                } catch {
                    networkManager.lastError = "Auto-start error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func statPill(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }
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
