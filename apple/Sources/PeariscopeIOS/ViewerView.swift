#if os(iOS)
import SwiftUI
import MetalKit
import UIKit
import PeariscopeCore
import AVKit

// MARK: - Viewer View

struct IOSViewerView: View {
    @ObservedObject var networkManager: NetworkManager
    @Binding var isInViewerMode: Bool
    @StateObject private var viewerSession: IOSViewerSession
    @State private var showControls = true
    @State private var controlsTask: Task<Void, Never>?
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var showShortcuts = false
    @State private var activeModifiers: InputModifiers = []

    init(networkManager: NetworkManager, isInViewerMode: Binding<Bool>) {
        self.networkManager = networkManager
        _isInViewerMode = isInViewerMode
        _viewerSession = StateObject(wrappedValue: IOSViewerSession(networkManager: networkManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Desktop view area — ends above the input bar
            ZStack {
                Color.black

                // Hidden sample buffer layer for PiP — must be in the view hierarchy
                PiPLayerRepresentable(viewerSession: viewerSession)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)

                IOSMetalViewRepresentable(viewerSession: viewerSession)

                IOSTouchOverlay(viewerSession: viewerSession, onUserInteraction: resetAutoHide)
                    .allowsHitTesting(true)

                // Remote cursor overlay (UIKit-based — no SwiftUI re-renders)
                CursorOverlayRepresentable(viewerSession: viewerSession)
                    .allowsHitTesting(false)

                // Auto-hiding top bar
                VStack {
                    if showControls {
                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(qualityColor)
                                    .frame(width: 5, height: 5)
                                    .shadow(color: qualityColor.opacity(0.6), radius: 3)
                                Text("\(Int(viewerSession.fps))")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                if viewerSession.latencyMs > 0 {
                                    Text("\(Int(viewerSession.latencyMs))ms")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(qualityColor)
                                }
                                if !viewerSession.bandwidthFormatted.isEmpty {
                                    Text(viewerSession.bandwidthFormatted)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())

                            Spacer()

                            Button {
                                NSLog("[viewer] disconnect button tapped")
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                viewerSession.disconnect()
                                isInViewerMode = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(width: 32, height: 32)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .contentShape(Rectangle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.opacity)
                    }

                    Spacer()
                }
            }
            .ignoresSafeArea(edges: .top)

            bottomInputArea
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            // Loading overlay — only before first frame
            if viewerSession.isActive && !viewerSession.hasReceivedFirstFrame && viewerSession.pendingPin == nil {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Waiting for video...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 60)

                    Spacer()

                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let squish = sin(t * 2 * .pi / 1.4)
                        let scaleX = 1.0 + 0.08 * squish
                        let scaleY = 1.0 - 0.08 * squish
                        let pulse = (1 + cos(t * 2 * .pi / 2.0)) / 2
                        let bounce = 1.0 + 0.03 * sin(t * 2 * .pi / 0.7)

                        ZStack {
                            Circle()
                                .stroke(Color.pearGreen.opacity(0.5), lineWidth: 2.5)
                                .frame(width: 100, height: 100)
                                .scaleEffect(1.0 + 0.4 * (1 - pulse))
                                .opacity(0.3 + pulse * 0.5)

                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 52, height: 52)
                                .scaleEffect(x: scaleX * bounce, y: scaleY * bounce)
                        }
                    }

                    Spacer()

                    // Diagnostic log for debugging video decode issues
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(viewerSession.diagnosticLines.suffix(30).enumerated()), id: \.offset) { i, line in
                                    Text(line)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .id(i)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .frame(maxHeight: 160)
                        .onChange(of: viewerSession.diagnosticLines.count) {
                            if let last = viewerSession.diagnosticLines.suffix(30).indices.last {
                                proxy.scrollTo(last - viewerSession.diagnosticLines.suffix(30).startIndex, anchor: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, 8)

                    Button {
                        viewerSession.disconnect()
                        isInViewerMode = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .overlay {
            // PIN entry overlay
            if viewerSession.pendingPin != nil {
                Color.black.ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 32))
                        .foregroundColor(.pearGreen)
                    Text("PIN Required")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Enter the host's PIN to connect:")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    if let fingerprint = viewerSession.hostFingerprint {
                        Text("Host fingerprint: \(fingerprint)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    TextField("", text: $viewerSession.pinEntryText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.pearGreen)
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .frame(width: 160)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onChange(of: viewerSession.pinEntryText) {
                            // Vary haptic intensity per digit — like DTMF tones on old phones
                            if let lastChar = viewerSession.pinEntryText.last,
                               let digit = lastChar.wholeNumberValue {
                                let intensity = 0.3 + Double(digit) * 0.07  // 0→0.30, 9→0.93
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: intensity)
                            } else if viewerSession.pinEntryText.isEmpty {
                                // Deletion
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
                            }
                        }
                    HStack(spacing: 16) {
                        Button {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            viewerSession.cancelPinChallenge()
                        } label: {
                            Text("Cancel")
                                .font(.body.weight(.medium))
                                .foregroundColor(.red)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            viewerSession.submitPin()
                        } label: {
                            Text("Connect")
                                .font(.body.weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Color.pearGreen)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(24)
                .background(Color(.systemBackground).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 40)
            }
        }
        .overlay {
            // Connection lost / reconnecting banners
            if viewerSession.connectionLost && !viewerSession.isReconnecting {
                VStack {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.title)
                            .foregroundStyle(.white)
                        Text("Connection Lost")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("All reconnect attempts failed.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: 16) {
                            Button {
                                viewerSession.retryConnection()
                            } label: {
                                Text("Retry")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Color.pearGreen)
                                    .clipShape(Capsule())
                            }
                            Button {
                                viewerSession.disconnect()
                                isInViewerMode = false
                            } label: {
                                Text("Disconnect")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.bottom, 80)
                }
            } else if viewerSession.isReconnecting {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        if case .reconnecting(let attempt, let max) = networkManager.reconnectionManager.state {
                            Text("Reconnecting (\(attempt)/\(max))...")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                        } else {
                            Text("Reconnecting...")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.bottom, 80)
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear {
            CrashLog.write("IOSViewerView.onAppear — isConnected=\(networkManager.isConnected) peers=\(networkManager.connectedPeers.count)")
            scheduleAutoHide()
            let binding = $isInViewerMode
            viewerSession.onExitViewer = {
                let stack = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
                CrashLog.write("EXIT VIEWER: isInViewerMode → false\n\(stack)")
                binding.wrappedValue = false
            }
        }
    }

    // [5] Quality color based on latency
    private var qualityColor: Color {
        let ms = viewerSession.latencyMs
        if ms <= 0 { return .pearGreen }
        if ms < 50 { return .green }
        if ms < 100 { return .yellow }
        if ms < 200 { return .orange }
        return .red
    }

    // [1] Auto-hide toolbar after 6 seconds (don't hide while typing)
    private func scheduleAutoHide() {
        controlsTask?.cancel()
        controlsTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if isInputFocused { return } // Don't hide while typing
            withAnimation(.easeOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    private func resetAutoHide() {
        if !showControls {
            withAnimation(.easeIn(duration: 0.2)) {
                showControls = true
            }
        }
        scheduleAutoHide()
    }

    private func sendInputText() {
        if inputText.isEmpty {
            viewerSession.sendVirtualKey(keycode: VK.return.rawValue)
        } else {
            // If modifiers are active, send each char as CGKeyCode with modifiers
            if !activeModifiers.isEmpty {
                for char in inputText.lowercased() {
                    if let keycode = Self.charToKeysym[char] {
                        viewerSession.sendKeyCombo(keycode: keycode, modifiers: activeModifiers)
                    }
                }
                activeModifiers = []
            } else {
                viewerSession.typeString(inputText)
            }
            inputText = ""
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // Map characters to X11 keysyms for modifier combos (lowercase ASCII = keysym)
    private static let charToKeysym: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        // a-z: X11 keysym = Unicode code point
        for c in "abcdefghijklmnopqrstuvwxyz" {
            map[c] = UInt32(c.asciiValue!)
        }
        // 0-9: X11 keysym = Unicode code point
        for c in "0123456789" {
            map[c] = UInt32(c.asciiValue!)
        }
        // Symbols
        for c: Character in ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`", " "] {
            map[c] = UInt32(c.asciiValue!)
        }
        return map
    }()

    /// Send a shortcut key combo, applying any active sticky modifiers too
    private func sendShortcut(keycode: UInt32, modifiers: InputModifiers = []) {
        let combined = modifiers.union(activeModifiers)
        viewerSession.sendKeyCombo(keycode: keycode, modifiers: combined)
        activeModifiers = []
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Bottom Input Area

    private var bottomInputArea: some View {
        VStack(spacing: 0) {
            if showShortcuts {
                shortcutsPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isInputFocused || showShortcuts {
                modifierKeysRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            mainInputBar
        }
        .background(.ultraThinMaterial)
    }

    private var mainInputBar: some View {
        HStack(spacing: 6) {
            Button {
                viewerSession.toggleKeyboard()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showShortcuts.toggle()
                }
            } label: {
                Image(systemName: "command.square")
                    .font(.system(size: 14))
                    .foregroundStyle(showShortcuts ? Color.pearGreen : .white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(showShortcuts ? Color.pearGreen.opacity(0.2) : .white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            TextField("Type here...", text: $inputText)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .tint(.pearGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit { sendInputText() }

            Button { sendInputText() } label: {
                Image(systemName: "return")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.pearGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                viewerSession.toggleMouseMode()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: viewerSession.isTrackpadMode ? "hand.point.up.left" : "computermouse")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            displaySwitcher
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var displaySwitcher: some View {
        if viewerSession.availableDisplays.count > 1 {
            Menu {
                ForEach(viewerSession.availableDisplays, id: \.displayID) { display in
                    Button {
                        viewerSession.switchDisplay(to: display.displayID)
                    } label: {
                        HStack {
                            Text(display.name.isEmpty ? "\(display.width)x\(display.height)" : display.name)
                            if display.displayID == viewerSession.activeDisplayId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "display.2")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Modifier Keys Row

    private var modifierKeysRow: some View {
        HStack(spacing: 6) {
            modifierPill("ctrl", flag: .control)
            modifierPill("alt", flag: .alt)
            modifierPill("shift", flag: .shift)
            modifierPill("cmd", flag: .meta)

            Spacer()

            // Escape key
            shortcutPill("esc") { sendShortcut(keycode: 53) }
            // Tab key
            shortcutPill("tab") { sendShortcut(keycode: 48) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func modifierPill(_ label: String, flag: InputModifiers) -> some View {
        let isActive = activeModifiers.contains(flag)
        return Button {
            if isActive {
                activeModifiers.remove(flag)
            } else {
                activeModifiers.insert(flag)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? .black : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? Color.pearGreen : .white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func shortcutPill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Shortcuts Panel

    // Platform-neutral virtual keycodes (X11 keysyms via VK enum in PeariscopeCore)
    private static let keycodeC: UInt32 = VK.c.rawValue
    private static let keycodeV: UInt32 = VK.v.rawValue
    private static let keycodeX: UInt32 = VK.x.rawValue
    private static let keycodeZ: UInt32 = VK.z.rawValue
    private static let keycodeA: UInt32 = VK.a.rawValue
    private static let keycodeF: UInt32 = VK.f.rawValue
    private static let keycodeS: UInt32 = VK.s.rawValue
    private static let keycodeW: UInt32 = VK.w.rawValue
    private static let keycodeT: UInt32 = VK.t.rawValue
    private static let keycodeQ: UInt32 = VK.q.rawValue
    private static let keycodeN: UInt32 = VK.n.rawValue
    private static let keycodeTab: UInt32 = VK.tab.rawValue
    private static let keycodeEsc: UInt32 = VK.escape.rawValue
    private static let keycodeDelete: UInt32 = VK.backspace.rawValue
    private static let keycodeForwardDelete: UInt32 = VK.delete.rawValue
    private static let keycodeReturn: UInt32 = VK.return.rawValue
    private static let keycodeSpace: UInt32 = VK.space.rawValue
    private static let keycodeUpArrow: UInt32 = VK.up.rawValue
    private static let keycodeDownArrow: UInt32 = VK.down.rawValue
    private static let keycodeLeftArrow: UInt32 = VK.left.rawValue
    private static let keycodeRightArrow: UInt32 = VK.right.rawValue
    private static let keycodeHome: UInt32 = VK.home.rawValue
    private static let keycodeEnd: UInt32 = VK.end.rawValue
    private static let keycodePageUp: UInt32 = VK.pageUp.rawValue
    private static let keycodePageDown: UInt32 = VK.pageDown.rawValue
    private static let keycodeF1: UInt32 = VK.f1.rawValue
    private static let keycodeF2: UInt32 = VK.f2.rawValue
    private static let keycodeF3: UInt32 = VK.f3.rawValue
    private static let keycodeF4: UInt32 = VK.f4.rawValue
    private static let keycodeF5: UInt32 = VK.f5.rawValue
    private static let keycodeF6: UInt32 = VK.f6.rawValue
    private static let keycodeF7: UInt32 = VK.f7.rawValue
    private static let keycodeF8: UInt32 = VK.f8.rawValue
    private static let keycodeF9: UInt32 = VK.f9.rawValue
    private static let keycodeF10: UInt32 = VK.f10.rawValue
    private static let keycodeF11: UInt32 = VK.f11.rawValue
    private static let keycodeF12: UInt32 = VK.f12.rawValue

    private var shortcutsPanel: some View {
        VStack(spacing: 8) {
            // Common shortcuts row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    shortcutButton("Copy", icon: "doc.on.doc") {
                        sendShortcut(keycode: Self.keycodeC, modifiers: .meta)
                    }
                    shortcutButton("Paste", icon: "doc.on.clipboard") {
                        sendShortcut(keycode: Self.keycodeV, modifiers: .meta)
                    }
                    shortcutButton("Cut", icon: "scissors") {
                        sendShortcut(keycode: Self.keycodeX, modifiers: .meta)
                    }
                    shortcutButton("Undo", icon: "arrow.uturn.backward") {
                        sendShortcut(keycode: Self.keycodeZ, modifiers: .meta)
                    }
                    shortcutButton("Redo", icon: "arrow.uturn.forward") {
                        sendShortcut(keycode: Self.keycodeZ, modifiers: [.meta, .shift])
                    }
                    shortcutButton("All", icon: "selection.pin.in.out") {
                        sendShortcut(keycode: Self.keycodeA, modifiers: .meta)
                    }
                    shortcutButton("Find", icon: "magnifyingglass") {
                        sendShortcut(keycode: Self.keycodeF, modifiers: .meta)
                    }
                    shortcutButton("Save", icon: "square.and.arrow.down") {
                        sendShortcut(keycode: Self.keycodeS, modifiers: .meta)
                    }
                    shortcutButton("New Tab", icon: "plus.square") {
                        sendShortcut(keycode: Self.keycodeT, modifiers: .meta)
                    }
                    shortcutButton("Close", icon: "xmark.square") {
                        sendShortcut(keycode: Self.keycodeW, modifiers: .meta)
                    }
                    shortcutButton("Quit", icon: "power") {
                        sendShortcut(keycode: Self.keycodeQ, modifiers: .meta)
                    }
                }
                .padding(.horizontal, 10)
            }

            // Navigation keys row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Arrow keys
                    shortcutButton("←", icon: nil) { sendShortcut(keycode: Self.keycodeLeftArrow) }
                    shortcutButton("↓", icon: nil) { sendShortcut(keycode: Self.keycodeDownArrow) }
                    shortcutButton("↑", icon: nil) { sendShortcut(keycode: Self.keycodeUpArrow) }
                    shortcutButton("→", icon: nil) { sendShortcut(keycode: Self.keycodeRightArrow) }

                    Divider().frame(height: 20).background(.white.opacity(0.2))

                    shortcutButton("Home", icon: nil) { sendShortcut(keycode: Self.keycodeHome) }
                    shortcutButton("End", icon: nil) { sendShortcut(keycode: Self.keycodeEnd) }
                    shortcutButton("PgUp", icon: nil) { sendShortcut(keycode: Self.keycodePageUp) }
                    shortcutButton("PgDn", icon: nil) { sendShortcut(keycode: Self.keycodePageDown) }
                    shortcutButton("Del", icon: nil) { sendShortcut(keycode: Self.keycodeForwardDelete) }
                    shortcutButton("Space", icon: nil) { sendShortcut(keycode: Self.keycodeSpace) }
                }
                .padding(.horizontal, 10)
            }

            // Function keys row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    shortcutButton("F1", icon: nil) { sendShortcut(keycode: Self.keycodeF1) }
                    shortcutButton("F2", icon: nil) { sendShortcut(keycode: Self.keycodeF2) }
                    shortcutButton("F3", icon: nil) { sendShortcut(keycode: Self.keycodeF3) }
                    shortcutButton("F4", icon: nil) { sendShortcut(keycode: Self.keycodeF4) }
                    shortcutButton("F5", icon: nil) { sendShortcut(keycode: Self.keycodeF5) }
                    shortcutButton("F6", icon: nil) { sendShortcut(keycode: Self.keycodeF6) }
                    shortcutButton("F7", icon: nil) { sendShortcut(keycode: Self.keycodeF7) }
                    shortcutButton("F8", icon: nil) { sendShortcut(keycode: Self.keycodeF8) }
                    shortcutButton("F9", icon: nil) { sendShortcut(keycode: Self.keycodeF9) }
                    shortcutButton("F10", icon: nil) { sendShortcut(keycode: Self.keycodeF10) }
                    shortcutButton("F11", icon: nil) { sendShortcut(keycode: Self.keycodeF11) }
                    shortcutButton("F12", icon: nil) { sendShortcut(keycode: Self.keycodeF12) }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 8)
    }

    private func shortcutButton(_ label: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let icon {
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 48, height: 38)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(minWidth: 36, minHeight: 32)
                    .padding(.horizontal, 4)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func toolbarButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isActive ? .pearGreen : .white.opacity(0.85))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isActive ? .pearGreen : .white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cursor Overlay (UIKit)

/// Wraps CursorView in SwiftUI
struct CursorOverlayRepresentable: UIViewRepresentable {
    let viewerSession: IOSViewerSession

    func makeUIView(context: Context) -> CursorView {
        return CursorView(session: viewerSession)
    }

    func updateUIView(_ uiView: CursorView, context: Context) {}

    static func dismantleUIView(_ uiView: CursorView, coordinator: ()) {
        uiView.cleanup()
    }
}

/// Lightweight UIView that renders cursor via CADisplayLink — no SwiftUI overhead
class CursorView: UIView {
    private weak var session: IOSViewerSession?
    private let cursorLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?
    // Current display position
    private var displayX: CGFloat = 0.5
    private var displayY: CGFloat = 0.5
    private var tickCount: Int = 0
    private var isLightBackground = false

    init(session: IOSViewerSession) {
        self.session = session
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        // Build cursor path (arrow shape)
        let path = UIBezierPath()
        let w: CGFloat = 18
        let h: CGFloat = 22
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h * 0.85))
        path.addLine(to: CGPoint(x: w * 0.25, y: h * 0.65))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: w * 0.65, y: h * 0.92))
        path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.58))
        path.close()

        cursorLayer.path = path.cgPath
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.4
        cursorLayer.shadowOffset = CGSize(width: 1, height: 1)
        cursorLayer.shadowRadius = 1.5
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.addSublayer(cursorLayer)

        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink?.add(to: .main, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }

    func cleanup() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let session, let renderer = session.renderer else {
            cursorLayer.isHidden = true
            return
        }

        // With local cursor updates, remoteCursorX/Y is set instantly from touch.
        // No smoothing needed — just track the target directly.
        displayX = CGFloat(session.remoteCursorX)
        displayY = CGFloat(session.remoteCursorY)

        let offset = renderer.viewportOffset
        let scale = renderer.viewportScale

        let viewX = CGFloat((Float(displayX) - offset.x) / scale.x) * bounds.width
        let viewY = CGFloat((Float(displayY) - offset.y) / scale.y) * bounds.height

        let inBounds = viewX >= -20 && viewX <= bounds.width + 20 && viewY >= -20 && viewY <= bounds.height + 20
        cursorLayer.isHidden = !inBounds || !session.hasReceivedFirstFrame

        if inBounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.position = CGPoint(x: viewX, y: viewY)

            // Sample brightness every ~10 ticks (~8-12Hz) for cursor color
            tickCount += 1
            if tickCount % 10 == 0 {
                if let brightness = renderer.sampleBrightness(atNormalized: Float(displayX), y: Float(displayY)) {
                    let wasLight = isLightBackground
                    isLightBackground = brightness > 0.5
                    if isLightBackground != wasLight {
                        cursorLayer.fillColor = isLightBackground ? UIColor.black.cgColor : UIColor.white.cgColor
                        cursorLayer.strokeColor = isLightBackground ? UIColor.white.cgColor : UIColor.black.cgColor
                    }
                }
            }

            CATransaction.commit()
        }
    }
}

// MARK: - Metal View (iOS)

struct IOSMetalViewRepresentable: UIViewRepresentable {
    let viewerSession: IOSViewerSession

    func makeUIView(context: Context) -> MTKView {
        CrashLog.write("IOSMetalViewRepresentable.makeUIView() — calling setup()")
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        viewerSession.setup(mtkView: mtkView)
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

// MARK: - PiP Sample Buffer Layer

/// UIView whose backing layer is AVSampleBufferDisplayLayer — required for PiP.
/// Must be in the view hierarchy (even at 1x1) for AVPictureInPictureController to work.
class PiPSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

struct PiPLayerRepresentable: UIViewRepresentable {
    let viewerSession: IOSViewerSession

    func makeUIView(context: Context) -> PiPSampleBufferView {
        let view = PiPSampleBufferView()
        view.sampleBufferLayer.videoGravity = .resizeAspect
        viewerSession.setupPiP(displayLayer: view.sampleBufferLayer)
        return view
    }

    func updateUIView(_ uiView: PiPSampleBufferView, context: Context) {}
}

// MARK: - Touch Overlay

struct IOSTouchOverlay: UIViewRepresentable {
    let viewerSession: IOSViewerSession
    var onUserInteraction: (() -> Void)?

    func makeUIView(context: Context) -> TouchInputView {
        let view = TouchInputView()
        view.viewerSession = viewerSession
        view.onUserInteraction = onUserInteraction
        view.isMultipleTouchEnabled = true
        view.setupKeyboardTextField()
        view.setupPinchGesture()  // [2] Pinch to zoom
        viewerSession.keyboardTextField = view.hiddenTextField
        return view
    }

    func updateUIView(_ uiView: TouchInputView, context: Context) {}
}

class TouchInputView: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    weak var viewerSession: IOSViewerSession?
    private var lastTouchLocation: CGPoint = .zero
    var hiddenTextField: UITextField?
    var onUserInteraction: (() -> Void)?

    private let topInset: CGFloat = 100
    private let bottomInset: CGFloat = 100

    // Haptic generators
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    private let longPressHaptic = UIImpactFeedbackGenerator(style: .medium)

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if point.y < topInset || point.y > bounds.height - bottomInset {
            return false
        }
        return true
    }

    func setupKeyboardTextField() {
        guard hiddenTextField == nil else { return }
        let tf = UITextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.delegate = self
        // Seed with a space so backspace always has something to delete
        tf.text = " "
        addSubview(tf)
        hiddenTextField = tf
    }

    // [2] Pinch-to-zoom gesture
    func setupPinchGesture() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // Double-tap to toggle between fit-to-screen and 1:1 pixel mapping
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
    }

    private var pinchStartZoom: Float = 1.0
    private(set) var isPinching = false

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let session = viewerSession else { return }
        onUserInteraction?()

        switch gesture.state {
        case .began:
            isPinching = true
            cancelLongPress()
            pinchStartZoom = session.userZoom
        case .changed:
            let newZoom = pinchStartZoom * Float(gesture.scale)
            session.userZoom = min(max(newZoom, 1.0), 5.0) // Clamp between 1x and 5x
            session.updateViewport()
        case .ended, .cancelled:
            // Snap back to 1.0 if very close
            if session.userZoom < 1.1 {
                session.userZoom = 1.0
                session.updateViewport()
            }
            // Delay clearing isPinching so touchesEnded doesn't fire a click
            DispatchQueue.main.async { self.isPinching = false }
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let session = viewerSession else { return }
        onUserInteraction?()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        if session.userZoom > 1.05 {
            // Currently zoomed in — snap back to fit-to-screen
            session.userZoom = 1.0
            session.userPanOffset = .zero
            session.updateViewport()
        } else {
            // Currently at fit — zoom to 1:1 pixel mapping centered on tap point
            guard let renderer = session.renderer else { return }
            let tapLoc = gesture.location(in: self)
            let viewportOffset = renderer.viewportOffset
            let viewportScale = renderer.viewportScale
            // Convert tap to desktop-normalized coordinates
            let desktopX = viewportOffset.x + Float(tapLoc.x / bounds.width) * viewportScale.x
            let desktopY = viewportOffset.y + Float(tapLoc.y / bounds.height) * viewportScale.y

            // Calculate zoom for 1:1: texture pixels == screen points
            let screen = UIScreen.main.nativeBounds
            let texW = session.textureWidth
            let texH = session.textureHeight
            guard texW > 0, texH > 0 else { return }
            // 1:1 means one texture pixel = one screen pixel
            // viewZoom = textureSize / screenSize (in the dominant axis)
            let zoomX = Float(texW) / Float(screen.width)
            let zoomY = Float(texH) / Float(screen.height)
            let targetZoom = min(max(zoomX, zoomY), 5.0)

            if targetZoom <= 1.05 {
                // Texture is smaller than screen — no point zooming in
                return
            }

            session.userZoom = targetZoom
            // Center on tap point
            session.cursorX = desktopX
            session.cursorY = desktopY
            session.userPanOffset = .zero
            session.updateViewport()
        }
    }

    // Allow pinch and touches simultaneously
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let session = viewerSession else { return false }

        // [4] Haptic on keypress
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.4)

        if string.isEmpty && range.length > 0 {
            sendVirtualKey(session: session, keycode: VK.backspace.rawValue)
            // Re-seed so next backspace also works
            DispatchQueue.main.async { textField.text = " " }
            return false
        }

        for char in string {
            if char == "\n" || char == "\r" {
                sendVirtualKey(session: session, keycode: VK.return.rawValue)
            } else if char == "\t" {
                sendVirtualKey(session: session, keycode: VK.tab.rawValue)
            } else {
                var keyEvent = Peariscope_KeyEvent()
                keyEvent.keycode = UInt32(char.unicodeScalars.first?.value ?? 0)
                keyEvent.pressed = true
                var down = Peariscope_InputEvent()
                down.key = keyEvent
                session.sendInput(down)

                keyEvent.pressed = false
                var up = Peariscope_InputEvent()
                up.key = keyEvent
                session.sendInput(up)
            }
        }
        // Keep text field seeded for backspace
        DispatchQueue.main.async { textField.text = " " }
        return false
    }

    private func sendVirtualKey(session: IOSViewerSession, keycode: UInt32) {
        var keyEvent = Peariscope_KeyEvent()
        keyEvent.keycode = keycode
        keyEvent.modifiers = 0x80000000
        keyEvent.pressed = true
        var down = Peariscope_InputEvent()
        down.key = keyEvent
        session.sendInput(down)

        keyEvent.pressed = false
        var up = Peariscope_InputEvent()
        up.key = keyEvent
        session.sendInput(up)
    }

    // Viewport snapshot to prevent feedback loop
    private var dragViewportOffset: SIMD2<Float> = .zero
    private var dragViewportScale: SIMD2<Float> = .init(1, 1)

    // Tap vs drag detection
    private var touchStartLocation: CGPoint = .zero
    private var touchStartTime: TimeInterval = 0
    private var isDragging = false
    private let dragThreshold: CGFloat = 18.0
    private let tapMaxDuration: TimeInterval = 0.25

    // [3] Long-press for drag
    private var isLongPressDragging = false
    private var longPressTimer: Timer?
    private let longPressDuration: TimeInterval = 0.4

    // [8] Trackpad mode: last position for relative movement
    private var trackpadLastLocation: CGPoint = .zero

    private func desktopLocationStable(_ touch: UITouch) -> CGPoint {
        let loc = touch.location(in: self)
        let screenNormX = loc.x / bounds.width
        let screenNormY = loc.y / bounds.height
        let desktopX = Double(dragViewportOffset.x) + screenNormX * Double(dragViewportScale.x)
        let desktopY = Double(dragViewportOffset.y) + screenNormY * Double(dragViewportScale.y)
        return CGPoint(x: desktopX, y: desktopY)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let session = viewerSession else { return }
        session.isTouching = true
        if isPinching { return }
        onUserInteraction?()

        if let renderer = session.renderer {
            dragViewportOffset = renderer.viewportOffset
            dragViewportScale = renderer.viewportScale
        }

        let location = desktopLocationStable(touch)
        lastTouchLocation = location
        touchStartLocation = touch.location(in: self)
        trackpadLastLocation = touch.location(in: self)
        touchStartTime = touch.timestamp
        isDragging = false
        isLongPressDragging = false

        let touchCount = event?.allTouches?.count ?? 1

        // Three-finger tap dismisses keyboard and shows controls
        if touchCount >= 3 {
            if hiddenTextField?.isFirstResponder == true {
                hiddenTextField?.resignFirstResponder()
            }
            onUserInteraction?()
            return
        }

        if touchCount == 2 {
            // Two-finger: right-click immediately
            cancelLongPress()
            // In trackpad mode, use cursor position (not touch position on screen)
            let clickLoc: CGPoint = session.isTrackpadMode
                ? CGPoint(x: Double(session.cursorX), y: Double(session.cursorY))
                : location
            let inputEvent = makeMouseButtonEvent(
                button: .right, pressed: true,
                x: Float(clickLoc.x), y: Float(clickLoc.y)
            )
            session.sendInput(inputEvent)
        } else if touchCount == 1 {
            if session.isTrackpadMode {
                // [8] Trackpad mode: don't move cursor on touch start, just record position
            } else {
                // Direct mode: move cursor to touch position
                let inputEvent = makeMouseMoveEvent(
                    x: Float(location.x), y: Float(location.y)
                )
                session.sendInput(inputEvent)
            }

            // [3] Start long-press timer for drag
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                guard let self, let session = self.viewerSession else { return }
                self.isLongPressDragging = true
                // Haptic to signal drag mode activated
                self.longPressHaptic.impactOccurred()
                // Send mouse-down to begin drag
                // In trackpad mode, use cursor position (not touch position on screen)
                let loc: CGPoint
                if session.isTrackpadMode {
                    loc = CGPoint(x: Double(session.cursorX), y: Double(session.cursorY))
                } else {
                    loc = self.lastTouchLocation
                }
                let down = makeMouseButtonEvent(
                    button: .left, pressed: true,
                    x: Float(loc.x), y: Float(loc.y)
                )
                session.sendInput(down)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let session = viewerSession else { return }
        if isPinching { return }
        onUserInteraction?()
        let touchCount = event?.allTouches?.count ?? 1

        // Check if we've moved beyond the drag threshold
        if !isDragging {
            let currentLoc = touch.location(in: self)
            let dx = currentLoc.x - touchStartLocation.x
            let dy = currentLoc.y - touchStartLocation.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance > dragThreshold {
                isDragging = true
                // Cancel long-press if we start moving quickly
                if !isLongPressDragging {
                    cancelLongPress()
                }
            }
        }

        if touchCount == 1 {
            if session.isTrackpadMode {
                // [8] Trackpad mode: relative movement
                let currentLoc = touch.location(in: self)
                let deltaScreenX = currentLoc.x - trackpadLastLocation.x
                let deltaScreenY = currentLoc.y - trackpadLastLocation.y
                trackpadLastLocation = currentLoc

                // Convert screen delta to desktop delta (scaled by viewport)
                let sensitivity: Float = 1.5
                let desktopDeltaX = Float(deltaScreenX) / Float(bounds.width) * dragViewportScale.x * sensitivity
                let desktopDeltaY = Float(deltaScreenY) / Float(bounds.height) * dragViewportScale.y * sensitivity

                // Move cursor relatively
                let newX = min(max(session.cursorX + desktopDeltaX, 0), 1)
                let newY = min(max(session.cursorY + desktopDeltaY, 0), 1)

                let inputEvent = makeMouseMoveEvent(x: newX, y: newY)
                session.sendInput(inputEvent)
                // Local cursor: update remoteCursorX/Y immediately so CursorView
                // moves without waiting for host round-trip. Host CursorPosition
                // messages will correct any drift.
                session.remoteCursorX = newX
                session.remoteCursorY = newY
                session.moveCursor(to: newX, to: newY)
                lastTouchLocation = CGPoint(x: Double(newX), y: Double(newY))
            } else {
                // Direct mode: absolute position
                let location = desktopLocationStable(touch)
                let inputEvent = makeMouseMoveEvent(
                    x: Float(location.x), y: Float(location.y)
                )
                session.sendInput(inputEvent)
                session.remoteCursorX = Float(location.x)
                session.remoteCursorY = Float(location.y)
                session.moveCursor(to: Float(location.x), to: Float(location.y))
                lastTouchLocation = location
            }
        } else if touchCount == 2 {
            let location = desktopLocationStable(touch)
            let deltaX = Float(location.x - lastTouchLocation.x) * 3
            let deltaY = Float(location.y - lastTouchLocation.y) * 3
            let inputEvent = makeScrollEvent(deltaX: deltaX, deltaY: deltaY)
            session.sendInput(inputEvent)
            lastTouchLocation = location
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let session = viewerSession else { return }
        if isPinching { cancelLongPress(); return }
        onUserInteraction?()
        cancelLongPress()

        let touchCount = touches.count
        let endLocation: CGPoint
        if session.isTrackpadMode {
            // In trackpad mode, use the current cursor position for clicks
            endLocation = CGPoint(x: Double(session.cursorX), y: Double(session.cursorY))
        } else {
            endLocation = desktopLocationStable(touch)
        }

        if touchCount == 1 {
            if isLongPressDragging {
                // [3] End long-press drag: release mouse button
                let up = makeMouseButtonEvent(
                    button: .left, pressed: false,
                    x: Float(endLocation.x), y: Float(endLocation.y)
                )
                session.sendInput(up)
            } else if !isDragging && (touch.timestamp - touchStartTime) < tapMaxDuration {
                // Tap = click (down + up) — only if short duration AND no drag
                // [4] Haptic on tap/click
                tapHaptic.impactOccurred()

                let down = makeMouseButtonEvent(
                    button: .left, pressed: true,
                    x: Float(endLocation.x), y: Float(endLocation.y)
                )
                session.sendInput(down)

                let up = makeMouseButtonEvent(
                    button: .left, pressed: false,
                    x: Float(endLocation.x), y: Float(endLocation.y)
                )
                session.sendInput(up)
            }
            // If it was just a drag (no long-press), no click
        } else {
            let inputEvent = makeMouseButtonEvent(
                button: .right, pressed: false,
                x: Float(endLocation.x), y: Float(endLocation.y)
            )
            session.sendInput(inputEvent)
        }

        // Update viewport to follow cursor AFTER touch ends
        session.moveCursor(to: Float(endLocation.x), to: Float(endLocation.y))
        session.isTouching = false
        session.lastTouchEndTime = CFAbsoluteTimeGetCurrent()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        viewerSession?.isTouching = false
        viewerSession?.lastTouchEndTime = CFAbsoluteTimeGetCurrent()
        if isLongPressDragging, let session = viewerSession {
            // Release mouse button if drag was cancelled
            let loc: CGPoint = session.isTrackpadMode
                ? CGPoint(x: Double(session.cursorX), y: Double(session.cursorY))
                : lastTouchLocation
            let up = makeMouseButtonEvent(
                button: .left, pressed: false,
                x: Float(loc.x), y: Float(loc.y)
            )
            session.sendInput(up)
        }
        isLongPressDragging = false
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }
}
#endif
