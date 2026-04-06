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
                    Picker(selection: $theme.current) {
                        ForEach(AppTheme.allCases) { t in
                            HStack {
                                Circle()
                                    .fill(t.accentColor)
                                    .frame(width: 14, height: 14)
                                Text(t.displayName)
                            }
                            .tag(t)
                        }
                    } label: {
                        Label("Theme", systemImage: "paintpalette")
                    }
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
