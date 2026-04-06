#if os(iOS)
import SwiftUI
import PeariscopeCore

struct IOSSettingsView: View {
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var isPresented: Bool

    @State private var localDiscoveryEnabled: Bool = UserDefaults.standard.object(forKey: "peariscope.localDiscovery") as? Bool ?? true

    var body: some View {
        NavigationStack {
            List {
                // Appearance
                Section {
                    HStack(spacing: 12) {
                        ForEach(AppTheme.allCases) { t in
                            Button {
                                theme.current = t
                                // Switch iOS app icon
                                if UIApplication.shared.supportsAlternateIcons {
                                    UIApplication.shared.setAlternateIconName(t.alternateIconName)
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(t.accentColor.gradient)
                                            .frame(height: 60)
                                        if theme.current == t {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 20))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    Text(t.displayName)
                                        .font(.system(size: 13, weight: theme.current == t ? .semibold : .regular))
                                        .foregroundStyle(theme.current == t ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Appearance")
                }

                // Discovery
                Section {
                    Toggle(isOn: $localDiscoveryEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Local Discovery")
                                    .font(.system(size: 15))
                                Text("Find hosts on the same WiFi")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "wifi")
                                .foregroundColor(.blue)
                        }
                    }
                    .onChange(of: localDiscoveryEnabled) {
                        UserDefaults.standard.set(localDiscoveryEnabled, forKey: "peariscope.localDiscovery")
                    }
                } header: {
                    Text("Discovery")
                }

                // About
                Section {
                    HStack {
                        Label("App Version", systemImage: "info.circle")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14, design: .monospaced))
                    }

                    HStack {
                        Label("Worklet", systemImage: "gearshape.2")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(networkManager.isWorkletAlive ? "Running" : "Stopped")
                            .foregroundStyle(networkManager.isWorkletAlive ? .green : .red)
                            .font(.system(size: 14))
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}
#endif
