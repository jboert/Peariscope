#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation
import PeariscopeCore

// MARK: - Connection Sounds

/// Premium connection/disconnection sounds with haptics.
@MainActor
final class ConnectionSounds {
    static let shared = ConnectionSounds()

    private let chimes = ChimeEngine()

    private init() {}

    /// Bright ascending chime for connection
    func playConnected() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let buffer = synthesizePremium(notes: [
            (freq: 880, dur: 0.06, vol: 0.25),   // A5 grace note
            (freq: 1318.5, dur: 0.15, vol: 0.3),  // E6 resolve
        ], sampleRate: 44100)
        play(buffer: buffer)
    }

    /// FaceTime-style "boop boop" disconnect sound
    func playDisconnected() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let buffer = synthesizePremium(notes: [
            (freq: 620, dur: 0.12, vol: 0.4),    // Eb5
            (freq: 466, dur: 0.18, vol: 0.35),   // Bb4 — down a 4th
        ], sampleRate: 44100)
        play(buffer: buffer)
    }

    /// Synthesize tones with harmonics + smooth envelope for a richer, less "beepy" sound
    private func synthesizePremium(notes: [(freq: Double, dur: Double, vol: Float)], sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        // Add a small gap between notes
        let gapDuration = 0.03
        // Sum the same truncated per-note counts the loop below writes. Truncating
        // the summed duration instead came out one frame short for the disconnect
        // chime, and that one-frame overrun tripped AVFAudio's heap guard when the
        // buffer was freed.
        let gapFrames = Int(gapDuration * sampleRate)
        let noteFrames = notes.reduce(0) { $0 + Int($1.dur * sampleRate) }
        let totalFrames = AVAudioFrameCount(noteFrames + gapFrames * max(0, notes.count - 1))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        guard let channelData = buffer.floatChannelData?[0] else { return buffer }

        // Zero fill
        for i in 0..<Int(totalFrames) { channelData[i] = 0 }

        var frameOffset = 0
        for note in notes {
            let frames = Int(note.dur * sampleRate)
            let attackFrames = Int(0.005 * sampleRate) // 5ms attack
            let releaseStart = Int(Double(frames) * 0.6) // release starts at 60%

            for i in 0..<frames {
                let t = Double(i) / sampleRate
                // Smooth envelope: quick attack, sustain, exponential release
                var envelope: Float
                if i < attackFrames {
                    envelope = Float(i) / Float(attackFrames)
                } else if i >= releaseStart {
                    let releaseProgress = Float(i - releaseStart) / Float(frames - releaseStart)
                    envelope = powf(1.0 - releaseProgress, 3.0)
                } else {
                    envelope = 1.0
                }

                // Fundamental + soft harmonics for warmth
                let fundamental = sinf(Float(2.0 * .pi * note.freq * t))
                let octave = 0.15 * sinf(Float(2.0 * .pi * note.freq * 2.0 * t))
                let fifth = 0.08 * sinf(Float(2.0 * .pi * note.freq * 1.5 * t))

                channelData[frameOffset + i] = note.vol * envelope * (fundamental + octave + fifth)
            }
            frameOffset += frames + gapFrames
        }

        return buffer
    }

    private func play(buffer: AVAudioPCMBuffer) {
        chimes.play(buffer)
    }
}

/// Plays the connection chimes on one long-lived engine, off the main thread.
///
/// This used to build a new AVAudioEngine per chime and release the previous one
/// on the main actor. Tearing down an engine takes an AVFAudio lock that a
/// stuck render thread can hold (see crashSignalHandler), so one engine that is
/// never released, driven from its own queue, keeps such a stall off the UI.
final class ChimeEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "peariscope.connection-chimes")
    // Touched only on `queue`.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = 0

    func play(_ buffer: AVAudioPCMBuffer) {
        // AVAudioPCMBuffer isn't Sendable; it is built fresh per chime and never
        // touched again by the caller.
        nonisolated(unsafe) let buffer = buffer
        queue.async { [self] in
            // AVAudioSession is configured once at app launch (PeariscopeAppDelegate).
            // Do NOT call setCategory/setActive here — it deadlocks.
            if engine == nil {
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                self.engine = engine
                self.player = player
            }
            guard let engine, let player else { return }
            // The engine stops on its own after an interruption or route change.
            if !engine.isRunning {
                do { try engine.start() } catch { return }
            }
            generation += 1
            let scheduled = generation
            player.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
                // Pause rather than stop/release so nothing gets torn down, and
                // only if no newer chime replaced this one.
                self?.queue.async {
                    guard let self, self.generation == scheduled else { return }
                    self.engine?.pause()
                }
            }
            if !player.isPlaying { player.play() }
        }
    }
}

// MARK: - Diagnostics sharing

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Logs a fatal signal to the crash log, then re-raises it for the system report.
///
/// Signals arrive on whichever thread faulted. This used to be a closure inside
/// the app delegate, which Swift 6 made main-actor isolated: on any other thread
/// its isolation check trapped again inside the handler and the thread hung
/// instead of dying. When that thread held an AVFAudio lock (a caulk heap-guard
/// trap while freeing an audio buffer), the main thread blocked on the same lock
/// and the app froze until the watchdog killed it (0x8BADF00D, 2026-11-07).
///
/// It must stay nonisolated and must not allocate — the heap may be what broke —
/// so it only writes a fixed string with write(2).
private nonisolated func crashSignalHandler(_ sig: Int32) {
    let msg: StaticString
    switch sig {
    case SIGABRT: msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: SIGABRT\"}\n"
    case SIGSEGV: msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: SIGSEGV\"}\n"
    case SIGBUS:  msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: SIGBUS\"}\n"
    case SIGILL:  msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: SIGILL\"}\n"
    case SIGTRAP: msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: SIGTRAP\"}\n"
    case SIGFPE:  msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: SIGFPE\"}\n"
    default:      msg = "{\"level\":\"fatal\",\"msg\":\"CRASH: signal\"}\n"
    }
    let fd = CrashLog.fd
    if fd >= 0 { _ = write(fd, msg.utf8Start, msg.utf8CodeUnitCount) }
    signal(sig, SIG_DFL)
    raise(sig)
}

class PeariscopeAppDelegate: NSObject, UIApplicationDelegate {
    private var memorySource: DispatchSourceMemoryPressure?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Ignore SIGPIPE — writing to a broken BareKit IPC pipe sends SIGPIPE,
        // which kills the app instantly with no error message. By ignoring it,
        // the write() call returns an error instead, which we handle gracefully.
        signal(SIGPIPE, SIG_IGN)

        // Configure AVAudioSession ONCE at launch. AVAudioSession.setCategory()
        // can deadlock the main thread when the audio session is contested (e.g.,
        // after a viewer session's audio engine was recently active). By configuring
        // it here, we avoid calling setCategory() during connection setup where it
        // blocks the main thread and freezes the PIN challenge overlay.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // Set up persistent crash log FIRST
        CrashLog.setup()

        if CrashLog.previousSessionCrashed {
            CrashLog.write("Previous session terminated by system (peak_mem: \(CrashLog.previousSessionPeakMem)MB)")
        }

        // Check if there's a previous crash log
        if let prev = CrashLog.readPrevious(), prev.contains("MEMORY WARNING") || prev.contains("CRASH") {
            NSLog("[app] Previous session log:\n%@", prev)
        }

        // Install crash signal handlers that write to persistent file
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashSignalHandler)
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSContentView(networkManager: networkManager)
                .tint(.pearGreen)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                networkManager.resumeNetworking()
            case .background:
                // DON'T suspend networking on background — keep DHT alive
                // so NAT mappings persist and subsequent connections are fast.
                // The worklet uses minimal CPU/memory when idle (just DHT keepalive).
                // Only suspend if memory is critically low (handled by memory pressure handlers).
                CrashLog.write("App entering background")
                CrashLog.write("App backgrounded — keeping DHT alive for warmth")
            default:
                break
            }
        }
    }
}

struct IOSContentView: View {
    @ObservedObject var networkManager: NetworkManager
    /// Tracks whether we're in viewer mode. Once entered, we stay in viewer
    /// even during brief disconnections/reconnections. Only cleared on explicit disconnect.
    @State private var isInViewerMode = false
    @State private var crashLogText: String?
    @State private var viewerSessionId = 0
    /// Diagnostic lines shown on the "Connecting..." screen
    @State private var connectingDiagLines: [String] = []
    static var exitViewerCount = 0

    var body: some View {
        NavigationStack {
            if isInViewerMode {
                IOSViewerView(networkManager: networkManager, isInViewerMode: $isInViewerMode)
                    .id(viewerSessionId)
            } else if networkManager.isConnected && !isInViewerMode {
                // Fallback: isConnected is true but onChange may not have fired yet
                Color.black.ignoresSafeArea().onAppear {
                    guard !isInViewerMode else { return }
                    CrashLog.write("PEER CONNECTED (body fallback): entering viewer mode")
                    viewerSessionId += 1
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
                CrashLog.write("PEER CONNECTED (onChange): mem=\(availMB)MB exitCount=\(Self.exitViewerCount) sessionId=\(viewerSessionId)→\(viewerSessionId+1)")
                // State changes FIRST — sound was blocking/crashing on 2nd connection,
                // preventing isInViewerMode from being set.
                viewerSessionId += 1
                isInViewerMode = true
                CrashLog.write("PEER CONNECTED: isInViewerMode=\(isInViewerMode) sessionId=\(viewerSessionId)")
                ConnectionSounds.shared.playConnected()
            }
            if !connected {
                CrashLog.write("PEER DISCONNECTED (onChange): isInViewerMode=\(isInViewerMode) exitCount=\(Self.exitViewerCount)")
            }
        }
        .onChange(of: isInViewerMode) { oldValue, newValue in
            if oldValue && !newValue {
                Self.exitViewerCount += 1
                CrashLog.write("isInViewerMode changed: true → false (exit #\(Self.exitViewerCount))")
                ConnectionSounds.shared.playDisconnected()
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
            // Wire up JS logs to CrashLog AND connecting diagnostics BEFORE starting runtime
            networkManager.onJSLog = { [self] msg in
                CrashLog.write("JS: \(msg)")
                DispatchQueue.main.async {
                    self.addConnectingDiag("JS: \(msg)")
                    // Parse warmup status from JS logs
                    if msg.contains("DHT bootstrapped") {
                        self.connectingStatus = "Network ready, searching..."
                    } else if msg.contains("DHT lookup flushed") {
                        self.connectingStatus = "Peer found, connecting..."
                    } else if msg.contains("Connection attempt") {
                        if let range = msg.range(of: #"attempt (\d+)/(\d+)"#, options: .regularExpression) {
                            self.connectingStatus = "Holepunching... (\(msg[range]))"
                        }
                    } else if msg.contains("Swarm connection:") {
                        self.connectingStatus = "Connected!"
                    } else if msg.contains("Initial DHT report:") {
                        if let range = msg.range(of: #"(\d+) nodes"#, options: .regularExpression) {
                            self.dhtNodeCount = Int(msg[range].split(separator: " ").first ?? "0") ?? 0
                        }
                    } else if msg.contains("Swarm update:") {
                        // Extract peers count
                        if let range = msg.range(of: #"peers=(\d+)"#, options: .regularExpression) {
                            let peersStr = msg[range].replacingOccurrences(of: "peers=", with: "")
                            if let peers = Int(peersStr), peers > 0, self.connectingStatus.contains("searching") {
                                self.connectingStatus = "Found \(peers) peer\(peers > 1 ? "s" : ""), holepunching..."
                            }
                        }
                    } else if msg.contains("Core modules loaded") {
                        self.connectingStatus = "Warming up network..."
                    } else if msg.contains("Hyperswarm listening") {
                        self.connectingStatus = "Network ready"
                    }
                }
            }
            // Start runtime immediately on launch so the DHT can bootstrap, run
            // NAT detection, and warm up the routing table BEFORE the user connects.
            // Keet's sidecar keeps its DHT alive permanently — this is the closest
            // we can get without a background process. With stock hyperdht tuning
            // (no aggressive punch overrides), idle DHT costs ~1 UDP ping per 5s.
            CrashLog.write("App launched — starting runtime for DHT warmup")
            do {
                try await networkManager.startRuntime()
                CrashLog.write("Runtime started for warmup, isAlive=\(networkManager.isWorkletAlive)")
            } catch {
                CrashLog.write("Runtime warmup failed: \(error) — will retry on connect")
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

    private func addConnectingDiag(_ line: String) {
        let ts = Self.diagFmt.string(from: Date())
        connectingDiagLines.append("\(ts) \(line)")
        if connectingDiagLines.count > 100 { connectingDiagLines.removeFirst() }
    }

    private static let diagFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    @State private var connectingElapsed: Int = 0
    @State private var connectingStatus: String = "Starting network..."
    @State private var dhtNodeCount: Int = 0
    @State private var diagExpanded: Bool = true
    @State private var diagCopiedFlash: Bool = false
    @State private var shareLogURL: IdentifiedURL?

    private static let fileTsFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private var connectingView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Animated radar/scan effect
            TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    // Rotating scan line
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(
                            AngularGradient(
                                colors: [.pearGreen.opacity(0), .pearGreen.opacity(0.6)],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 140, height: 140)
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 3.0) / 3.0 * 360))

                    // Pulsing rings
                    ForEach(0..<3, id: \.self) { i in
                        let phase = (t + Double(i) * 0.8).truncatingRemainder(dividingBy: 2.4)
                        let scale = 0.5 + phase / 2.4 * 0.7
                        let opacity = max(0, 1.0 - phase / 2.4)
                        Circle()
                            .stroke(Color.pearGreen.opacity(opacity * 0.3), lineWidth: 1.5)
                            .frame(width: 140, height: 140)
                            .scaleEffect(scale)
                    }

                    // Center icon
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }
                .frame(width: 160, height: 160)
            }

            VStack(spacing: 6) {
                Text("Connecting")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text(connectingStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.3), value: connectingStatus)

                if let phase = networkManager.connectionPhaseDetail {
                    Text(phase)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: networkManager.connectionPhaseDetail)
                }

                HStack(spacing: 8) {
                    // Elapsed timer
                    Text(connectingElapsed < 60
                         ? "\(connectingElapsed)s"
                         : "\(connectingElapsed / 60)m \(connectingElapsed % 60)s")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    if dhtNodeCount > 0 {
                        Text("\(dhtNodeCount) nodes")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.top, 24)

            Spacer()

            // Diagnostic log (expanded by default for debugging)
            DisclosureGroup(isExpanded: $diagExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = CrashLog.read() ?? connectingDiagLines.joined(separator: "\n")
                            diagCopiedFlash = true
                            Task {
                                try? await Task.sleep(for: .milliseconds(1200))
                                diagCopiedFlash = false
                            }
                        } label: {
                            Label(diagCopiedFlash ? "Copied" : "Copy",
                                  systemImage: diagCopiedFlash ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(diagCopiedFlash ? .green : .secondary)
                        Button {
                            let log = CrashLog.read() ?? connectingDiagLines.joined(separator: "\n")
                            let ts = Self.fileTsFmt.string(from: Date())
                            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("peariscope-\(ts).log")
                            do {
                                try log.write(to: url, atomically: true, encoding: .utf8)
                                shareLogURL = IdentifiedURL(url: url)
                            } catch {
                                NSLog("[diag] write share log failed: %@", error.localizedDescription)
                            }
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .sheet(item: $shareLogURL) { wrapped in
                        ShareSheet(items: [wrapped.url])
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(connectingDiagLines.enumerated()), id: \.offset) { i, line in
                                    Text(line)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .id(i)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: connectingDiagLines.count) {
                            if let last = connectingDiagLines.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(networkManager.isWorkletAlive ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text("Diagnostics")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

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

            Button {
                networkManager.disconnectAll()
                connectingDiagLines.removeAll()
                connectingElapsed = 0
            } label: {
                Text("Cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 80, height: 36)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .onAppear {
            connectingDiagLines.removeAll()
            connectingElapsed = 0
            addConnectingDiag("worklet alive: \(networkManager.isWorkletAlive)")
            addConnectingDiag("bridge: \(networkManager.bridgeDiagnosticSummary())")
            CrashLog.write("[connecting] onAppear: isConnecting=\(networkManager.isConnecting) isConnected=\(networkManager.isConnected) alive=\(networkManager.isWorkletAlive)")
            // Elapsed timer
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                guard networkManager.isConnecting else {
                    CrashLog.write("[connecting] elapsed timer stopped: isConnecting=false")
                    timer.invalidate()
                    return
                }
                connectingElapsed += 1
            }
            // Periodic diagnostics
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { timer in
                guard networkManager.isConnecting else {
                    timer.invalidate()
                    return
                }
                addConnectingDiag("bridge: \(networkManager.bridgeDiagnosticSummary())")
            }
        }
    }
}
#endif
