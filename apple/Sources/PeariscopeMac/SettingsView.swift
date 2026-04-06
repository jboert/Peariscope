import SwiftUI
import ServiceManagement
import PeariscopeCore

// MARK: - Settings View (Popover)

struct SettingsView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject private var theme = ThemeManager.shared
    let onBack: () -> Void

    @State private var maxViewers: Int = UserDefaults.standard.integer(forKey: "peariscope.maxViewers").clamped(to: 1...20, default: 5)
    @State private var requirePin: Bool = UserDefaults.standard.object(forKey: "peariscope.requirePin") as? Bool ?? true
    @State private var skipPinOnReconnect: Bool = UserDefaults.standard.bool(forKey: "peariscope.skipPinOnReconnect")
    @State private var pinCode: String = HostSession.loadPinFromKeychain()
    @State private var newCodeEachSession: Bool = UserDefaults.standard.bool(forKey: "peariscope.newCodeEachSession")
    @State private var adaptiveResolution: Bool = UserDefaults.standard.object(forKey: "peariscope.adaptiveResolution") as? Bool ?? true
    @State private var startSharingOnStartup: Bool = UserDefaults.standard.bool(forKey: "peariscope.startSharingOnStartup")
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var clipboardSync: Bool = UserDefaults.standard.object(forKey: "peariscope.clipboardSync") as? Bool ?? true
    @State private var audioEnabled: Bool = UserDefaults.standard.object(forKey: "peariscope.audioEnabled") as? Bool ?? true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                // --- Appearance ---
                sectionHeader("Appearance")

                settingRow(
                    icon: "paintpalette.fill",
                    iconColor: ThemeManager.shared.current.accentColor,
                    title: "Theme",
                    subtitle: "App color scheme"
                ) {
                    Picker("", selection: $theme.current) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                // --- Security ---
                sectionHeader("Security")

                settingToggle(
                    icon: "lock.shield.fill",
                    iconColor: .orange,
                    title: "PIN Protection",
                    subtitle: "Require PIN to connect",
                    isOn: $requirePin
                )
                .onChange(of: requirePin) { save("peariscope.requirePin", requirePin) }

                if requirePin {
                    HStack(spacing: 8) {
                        Spacer().frame(width: 32)
                        TextField("PIN (6+ chars)", text: $pinCode)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(pinCode.count < 6 ? Color.orange.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .frame(maxWidth: 130)
                            .onChange(of: pinCode) {
                                // Only save PINs with 6+ characters
                                if pinCode.count >= 6 {
                                    save("peariscope.pinCode", pinCode)
                                }
                            }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                    settingToggle(
                        icon: "arrow.triangle.2.circlepath",
                        iconColor: .green,
                        title: "Skip PIN on Reconnect",
                        subtitle: "Auto-approve peers that already passed PIN",
                        isOn: $skipPinOnReconnect
                    )
                    .onChange(of: skipPinOnReconnect) { save("peariscope.skipPinOnReconnect", skipPinOnReconnect) }
                }

                settingRow(
                    icon: "person.2.fill",
                    iconColor: .blue,
                    title: "Max Viewers",
                    subtitle: "Simultaneous connections"
                ) {
                    HStack(spacing: 0) {
                        Button { if maxViewers > 1 { maxViewers -= 1; save("peariscope.maxViewers", maxViewers) } } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Text("\(maxViewers)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 24)

                        Button { if maxViewers < 20 { maxViewers += 1; save("peariscope.maxViewers", maxViewers) } } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.04))
                    )
                }

                // --- Streaming ---
                sectionHeader("Streaming")
                    .padding(.top, 6)

                settingToggle(
                    icon: "arrow.up.left.and.arrow.down.right",
                    iconColor: .pearGreen,
                    title: "Adaptive Resolution",
                    subtitle: "Match viewer screen size",
                    isOn: $adaptiveResolution
                )
                .onChange(of: adaptiveResolution) { save("peariscope.adaptiveResolution", adaptiveResolution) }

                settingToggle(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: .purple,
                    title: "New Code Each Session",
                    subtitle: "Fresh seed phrase per share",
                    isOn: $newCodeEachSession
                )
                .onChange(of: newCodeEachSession) { save("peariscope.newCodeEachSession", newCodeEachSession) }

                settingToggle(
                    icon: "doc.on.clipboard",
                    iconColor: .teal,
                    title: "Clipboard Sync",
                    subtitle: "Share clipboard with viewers",
                    isOn: $clipboardSync
                )
                .onChange(of: clipboardSync) { save("peariscope.clipboardSync", clipboardSync) }

                settingToggle(
                    icon: "speaker.wave.2.fill",
                    iconColor: .indigo,
                    title: "Stream Audio",
                    subtitle: "Share system audio with viewers",
                    isOn: $audioEnabled
                )
                .onChange(of: audioEnabled) { save("peariscope.audioEnabled", audioEnabled) }

                // --- System ---
                sectionHeader("System")
                    .padding(.top, 6)

                settingToggle(
                    icon: "play.fill",
                    iconColor: .pearGreen,
                    title: "Auto-Share on Launch",
                    subtitle: "Start sharing when app opens",
                    isOn: $startSharingOnStartup
                )
                .onChange(of: startSharingOnStartup) { save("peariscope.startSharingOnStartup", startSharingOnStartup) }

                settingToggle(
                    icon: "person.badge.key.fill",
                    iconColor: .cyan,
                    title: "Launch at Login",
                    subtitle: "Start with macOS",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        NSLog("[settings] Failed to update login item: \(error)")
                    }
                }

                Spacer().frame(height: 8)
            }
        }
        .frame(maxHeight: 420)
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func settingToggle(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        settingRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func settingRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(iconColor.gradient)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
        if self == 0 { return defaultValue }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
