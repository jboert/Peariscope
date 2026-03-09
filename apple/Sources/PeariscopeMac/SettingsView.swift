import SwiftUI
import ServiceManagement
import PeariscopeCore

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var networkManager: NetworkManager
    @State private var maxViewers: Int = UserDefaults.standard.integer(forKey: "peariscope.maxViewers").clamped(to: 1...20, default: 5)
    @State private var requirePin: Bool = UserDefaults.standard.object(forKey: "peariscope.requirePin") as? Bool ?? true
    @State private var pinCode: String = UserDefaults.standard.string(forKey: "peariscope.pinCode") ?? ""
    @State private var newCodeEachSession: Bool = UserDefaults.standard.bool(forKey: "peariscope.newCodeEachSession")
    @State private var adaptiveResolution: Bool = UserDefaults.standard.object(forKey: "peariscope.adaptiveResolution") as? Bool ?? true
    @State private var startSharingOnStartup: Bool = UserDefaults.standard.bool(forKey: "peariscope.startSharingOnStartup")
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var startMinimized: Bool = UserDefaults.standard.bool(forKey: "peariscope.startMinimized")
    @State private var saved = false
    @State private var hoveredSection: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .thin))
                        .foregroundStyle(.pearGradient)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Settings")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Configure your Peariscope host")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

                VStack(spacing: 2) {
                    // --- Security Section ---
                    settingsSectionHeader("Security", icon: "shield.lefthalf.filled")

                    settingsCard(id: "pin") {
                        settingsRow(
                            icon: "lock.shield.fill",
                            iconColor: .orange,
                            title: "PIN Protection",
                            subtitle: "Require a PIN code before viewers can connect"
                        ) {
                            Toggle("", isOn: $requirePin)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }

                        if requirePin {
                            Divider().padding(.leading, 36)
                            HStack(spacing: 10) {
                                Spacer().frame(width: 26)
                                TextField("Enter PIN", text: $pinCode)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                    .frame(maxWidth: 140)
                                Spacer()
                            }
                            .padding(.vertical, 4)

                            if pinCode.count < 6 {
                                HStack(spacing: 4) {
                                    Spacer().frame(width: 26)
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(.orange)
                                    Text("PIN must be at least 6 characters")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                    Spacer()
                                }
                            }
                        }
                    }

                    settingsCard(id: "viewers") {
                        HStack(spacing: 10) {
                            settingsIcon("person.2.fill", color: .blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Max Viewers")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Limit simultaneous connections")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            HStack(spacing: 0) {
                                Button { if maxViewers > 1 { maxViewers -= 1 } } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())

                                Text("\(maxViewers)")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .frame(width: 28)

                                Button { if maxViewers < 20 { maxViewers += 1 } } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                    }

                    // --- Streaming Section ---
                    settingsSectionHeader("Streaming", icon: "wave.3.right")
                        .padding(.top, 8)

                    settingsCard(id: "adaptive") {
                        settingsRow(
                            icon: "arrow.up.left.and.arrow.down.right",
                            iconColor: .pearGreen,
                            title: "Adaptive Resolution",
                            subtitle: "Downscale capture to match viewer screen size"
                        ) {
                            Toggle("", isOn: $adaptiveResolution)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }

                    settingsCard(id: "seed") {
                        settingsRow(
                            icon: "arrow.triangle.2.circlepath",
                            iconColor: .purple,
                            title: "New Code Each Session",
                            subtitle: "Generate a fresh seed phrase every time you share"
                        ) {
                            Toggle("", isOn: $newCodeEachSession)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }

                    // --- System Section ---
                    settingsSectionHeader("System", icon: "laptopcomputer")
                        .padding(.top, 8)

                    settingsCard(id: "startup") {
                        settingsRow(
                            icon: "play.fill",
                            iconColor: .pearGreen,
                            title: "Auto-Share on Launch",
                            subtitle: "Start sharing your screen when the app opens"
                        ) {
                            Toggle("", isOn: $startSharingOnStartup)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }

                    settingsCard(id: "login") {
                        settingsRow(
                            icon: "person.badge.key.fill",
                            iconColor: .cyan,
                            title: "Launch at Login",
                            subtitle: "Automatically start Peariscope when you sign in"
                        ) {
                            Toggle("", isOn: $launchAtLogin)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }

                    settingsCard(id: "minimize") {
                        settingsRow(
                            icon: "menubar.arrow.up.rectangle",
                            iconColor: .indigo,
                            title: "Start Minimized",
                            subtitle: "Open in the menu bar without showing the window"
                        ) {
                            Toggle("", isOn: $startMinimized)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }
                }
                .padding(.horizontal, 20)

                // Save button
                Button {
                    saveSettings()
                } label: {
                    HStack(spacing: 6) {
                        if saved {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .transition(.scale.combined(with: .opacity))
                            Text("Saved")
                                .font(.system(size: 12, weight: .semibold))
                        } else {
                            Text("Save Changes")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(saved ? Color.pearGreen : Color.pearGreen.opacity(0.85))
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(requirePin && pinCode.count < 6)
                .opacity(requirePin && pinCode.count < 6 ? 0.5 : 1.0)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Components

    private func settingsSectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .padding(.top, 4)
    }

    private func settingsCard(id: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(hoveredSection == id ? 0.08 : 0.03), radius: hoveredSection == id ? 8 : 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(hoveredSection == id ? 0.1 : 0.05), lineWidth: 1)
        )
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredSection = isHovered ? id : nil
            }
        }
        .padding(.bottom, 4)
    }

    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            settingsIcon(icon, color: iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }

    private func settingsIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.gradient)
            )
    }

    private func saveSettings() {
        UserDefaults.standard.set(maxViewers, forKey: "peariscope.maxViewers")
        UserDefaults.standard.set(requirePin, forKey: "peariscope.requirePin")
        UserDefaults.standard.set(pinCode, forKey: "peariscope.pinCode")
        UserDefaults.standard.set(newCodeEachSession, forKey: "peariscope.newCodeEachSession")
        UserDefaults.standard.set(adaptiveResolution, forKey: "peariscope.adaptiveResolution")
        UserDefaults.standard.set(startSharingOnStartup, forKey: "peariscope.startSharingOnStartup")
        UserDefaults.standard.set(startMinimized, forKey: "peariscope.startMinimized")
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[settings] Failed to update login item: \(error)")
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.25)) { saved = false }
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
        if self == 0 { return defaultValue }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
