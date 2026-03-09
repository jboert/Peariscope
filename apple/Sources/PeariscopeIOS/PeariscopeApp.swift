#if os(iOS)
import SwiftUI
import UIKit
import PeariscopeCore

class PeariscopeAppDelegate: NSObject, UIApplicationDelegate {
    private var memorySource: DispatchSourceMemoryPressure?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Ignore SIGPIPE — writing to a broken BareKit IPC pipe sends SIGPIPE,
        // which kills the app instantly with no error message. By ignoring it,
        // the write() call returns an error instead, which we handle gracefully.
        signal(SIGPIPE, SIG_IGN)

        // Set up persistent crash log FIRST
        CrashLog.setup()

        // Check if there's a previous crash log
        if let prev = CrashLog.readPrevious(), prev.contains("MEMORY WARNING") || prev.contains("CRASH") {
            NSLog("[app] Previous session log:\n%@", prev)
        }

        // Install crash signal handlers that write to persistent file
        let crashSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]
        for sig in crashSignals {
            signal(sig) { sigNum in
                let name: String
                switch sigNum {
                case SIGABRT: name = "SIGABRT"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS:  name = "SIGBUS"
                case SIGILL:  name = "SIGILL"
                case SIGTRAP: name = "SIGTRAP"
                case SIGFPE:  name = "SIGFPE"
                default:      name = "SIG\(sigNum)"
                }
                CrashLog.write("CRASH: \(name) (\(sigNum)) — memory: \(os_proc_available_memory() / 1_048_576) MB")
                // Re-raise to get the default crash report
                signal(sigNum, SIG_DFL)
                raise(sigNum)
            }
        }

        // Monitor memory pressure — jetsam kills bypass signal handlers,
        // but we get a warning first that we can log
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let level: String
            switch source?.data {
            case .warning: level = "WARNING"
            case .critical: level = "CRITICAL"
            default: level = "UNKNOWN"
            }
            CrashLog.write("MEMORY WARNING: \(level) — available: \(os_proc_available_memory() / 1_048_576) MB")
        }
        source.resume()
        memorySource = source

        // Log memory on app lifecycle events
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            CrashLog.write("UIKit MEMORY WARNING — available: \(os_proc_available_memory() / 1_048_576) MB")
        }

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        CrashLog.write("App terminating normally")
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppOrientationLock.orientationLock
    }
}

@main
struct PeariscopeIOSApp: App {
    @UIApplicationDelegateAdaptor(PeariscopeAppDelegate.self) var appDelegate
    @StateObject private var networkManager = NetworkManager()

    var body: some Scene {
        WindowGroup {
            IOSContentView(networkManager: networkManager)
                .tint(.pearGreen)
        }
    }
}

struct IOSContentView: View {
    @ObservedObject var networkManager: NetworkManager
    /// Tracks whether we're in viewer mode. Once entered, we stay in viewer
    /// even during brief disconnections/reconnections. Only cleared on explicit disconnect.
    @State private var isInViewerMode = false
    @State private var crashLogText: String?
    static var exitViewerCount = 0

    var body: some View {
        NavigationStack {
            if isInViewerMode {
                IOSViewerView(networkManager: networkManager, isInViewerMode: $isInViewerMode)
            } else if networkManager.isConnected {
                // Fallback: isConnected is true but onChange may not have fired yet
                Color.black.ignoresSafeArea().onAppear {
                    CrashLog.write("PEER CONNECTED (body fallback): entering viewer mode")
                    isInViewerMode = true
                }
            } else if networkManager.isConnecting {
                connectingView
            } else {
                IOSConnectView(networkManager: networkManager)
            }
        }
        .onChange(of: networkManager.isConnected) { _, connected in
            if connected && !isInViewerMode {
                let availMB = os_proc_available_memory() / 1_048_576
                CrashLog.write("PEER CONNECTED (onChange): mem=\(availMB)MB exitCount=\(Self.exitViewerCount)")
                isInViewerMode = true
            }
            if !connected {
                CrashLog.write("PEER DISCONNECTED (onChange): isInViewerMode=\(isInViewerMode) exitCount=\(Self.exitViewerCount)")
            }
        }
        .onChange(of: isInViewerMode) { oldValue, newValue in
            if oldValue && !newValue {
                Self.exitViewerCount += 1
                CrashLog.write("isInViewerMode changed: true → false (exit #\(Self.exitViewerCount))")
            }
        }
        .task {
            // Show previous crash log if app died unexpectedly
            if let log = CrashLog.readPrevious(),
               !log.isEmpty,
               !log.contains("App terminating normally"),
               log.contains("heartbeat:") {
                // Had heartbeats but no clean termination = crash
                crashLogText = log
            }
            do {
                try await networkManager.startRuntime()
            } catch {
                networkManager.lastError = "Failed to start Pear runtime: \(error.localizedDescription)"
            }
        }
        .alert("Previous Session Crash Log", isPresented: .constant(crashLogText != nil)) {
            Button("Copy to Clipboard") {
                UIPasteboard.general.string = crashLogText
                crashLogText = nil
            }
            Button("Dismiss", role: .cancel) {
                crashLogText = nil
            }
        } message: {
            if let log = crashLogText {
                // Show last 500 chars to fit in alert
                let suffix = log.count > 500 ? "...\n" + log.suffix(500) : log
                Text(suffix)
            }
        }
    }

    @State private var pulsePhase = false

    private var connectingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                // Pulsing rings
                Circle()
                    .stroke(Color.pearGreen.opacity(0.1), lineWidth: 2)
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulsePhase ? 1.3 : 0.9)
                    .opacity(pulsePhase ? 0 : 0.6)
                Circle()
                    .stroke(Color.pearGreen.opacity(0.15), lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .scaleEffect(pulsePhase ? 1.2 : 1.0)
                    .opacity(pulsePhase ? 0.2 : 0.8)

                // Center icon
                ZStack {
                    Circle()
                        .fill(Color.pearGreenDim)
                        .frame(width: 52, height: 52)
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                }
            }
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: false), value: pulsePhase)
            .onAppear { pulsePhase = true }

            VStack(spacing: 4) {
                Text("Connecting")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Finding peer via DHT network")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button {
                networkManager.disconnectAll()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.pearGreen)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .background(Color.pearGreenDim)
                    .clipShape(Capsule())
            }

            if let error = networkManager.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.08))
                    .clipShape(Capsule())
                    .padding(.horizontal)
            }

            Spacer()

            Text("Long-press for debug log")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.3))
                .onLongPressGesture(minimumDuration: 2) {
                    crashLogText = CrashLog.read() ?? "No log"
                }
                .padding(.bottom, 6)
        }
        .background(Color(.systemBackground))
    }
}
#endif
