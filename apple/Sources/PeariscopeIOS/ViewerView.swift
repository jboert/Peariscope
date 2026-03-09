#if os(iOS)
import SwiftUI
import MetalKit
import UIKit
import PeariscopeCore

// MARK: - Viewer View

struct IOSViewerView: View {
    @ObservedObject var networkManager: NetworkManager
    @Binding var isInViewerMode: Bool
    @StateObject private var viewerSession: IOSViewerSession
    @State private var showControls = true
    @State private var controlsTask: Task<Void, Never>?
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

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

            // Bottom input bar — always visible, desktop ends above this
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

                TextField("Enter text...", text: $inputText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .tint(.pearGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($isInputFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        sendInputText()
                    }

                Button {
                    sendInputText()
                } label: {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            // Loading overlay — only before first frame
            if viewerSession.isActive && !viewerSession.hasReceivedFirstFrame && viewerSession.pendingPin == nil {
                Color.black.ignoresSafeArea()
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let squish = sin(t * 2 * .pi / 1.4)
                    let scaleX = 1.0 + 0.08 * squish
                    let scaleY = 1.0 - 0.08 * squish
                    let pulse = (1 + cos(t * 2 * .pi / 2.0)) / 2
                    let bounce = 1.0 + 0.03 * sin(t * 2 * .pi / 0.7)

                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .stroke(Color.pearGreen.opacity(0.15), lineWidth: 2)
                                .frame(width: 100, height: 100)
                                .scaleEffect(1.0 + 0.4 * (1 - pulse))
                                .opacity(pulse * 0.5)

                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 52, height: 52)
                                .scaleEffect(x: scaleX * bounce, y: scaleY * bounce)
                        }

                        Text("Waiting for video...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))

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
                        .padding(.top, 8)
                    }
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
                    HStack(spacing: 16) {
                        Button {
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
            if viewerSession.connectionLost {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .font(.title)
                            .foregroundStyle(.white)
                        Text("Connection Lost")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Returning to home screen...")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.bottom, 80)
                }
                .onAppear {
                    // Auto-exit after showing the message briefly
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        viewerSession.disconnect()
                        isInViewerMode = false
                    }
                }
            } else if viewerSession.isReconnecting {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Reconnecting...")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
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

    // [1] Auto-hide toolbar after 3 seconds (don't hide while typing)
    private func scheduleAutoHide() {
        controlsTask?.cancel()
        controlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
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
            viewerSession.sendVirtualKey(keycode: 36)
        } else {
            viewerSession.typeString(inputText)
            inputText = ""
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            CATransaction.commit()
        }
    }
}

// MARK: - Metal View (iOS)

struct IOSMetalViewRepresentable: UIViewRepresentable {
    let viewerSession: IOSViewerSession

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        viewerSession.setup(mtkView: mtkView)
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
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

    // Allow pinch and touches simultaneously
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let session = viewerSession else { return false }

        // [4] Haptic on keypress
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.4)

        if string.isEmpty && range.length > 0 {
            sendVirtualKey(session: session, keycode: 51)  // Backspace
            // Re-seed so next backspace also works
            DispatchQueue.main.async { textField.text = " " }
            return false
        }

        for char in string {
            if char == "\n" || char == "\r" {
                sendVirtualKey(session: session, keycode: 36)
            } else if char == "\t" {
                sendVirtualKey(session: session, keycode: 48)
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
            let inputEvent = makeMouseButtonEvent(
                button: .right, pressed: true,
                x: Float(location.x), y: Float(location.y)
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
                let loc = self.lastTouchLocation
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
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        if isLongPressDragging, let session = viewerSession {
            // Release mouse button if drag was cancelled
            let up = makeMouseButtonEvent(
                button: .left, pressed: false,
                x: Float(lastTouchLocation.x), y: Float(lastTouchLocation.y)
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
