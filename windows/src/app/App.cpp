#include "App.h"
#include "messages.pb.h"
#include <windowsx.h>
#include <wrl/client.h>
#include <sstream>
#include <chrono>

using Microsoft::WRL::ComPtr;

namespace peariscope {

static const wchar_t* WINDOW_CLASS = L"PeariscopeWindow";
static const wchar_t* WINDOW_TITLE = L"Peariscope";

App::App(HINSTANCE hInstance) : hInstance_(hInstance) {}

App::~App() {
    StopHosting();
    Disconnect();
    if (ipcBridge_) ipcBridge_->Stop();
    CoUninitialize();
}

bool App::Initialize(int nCmdShow) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    keyManager_ = std::make_unique<KeyManager>();
    ipcBridge_ = std::make_unique<IpcBridge>();
    SetupIpcCallbacks();

    if (!CreateMainWindow(nCmdShow)) return false;

    CreateControls(mainWindow_);
    UpdateControlVisibility();

    // Load settings
    // TODO: Use registry or settings file
    requirePin_ = false;
    pinCode_ = "";

    // Start the Pear worklet
    if (!ipcBridge_->Start()) {
        statusText_ = "Failed to start networking";
        MessageBoxW(mainWindow_,
                    L"Failed to start Pear runtime.\n"
                    L"Make sure Node.js is installed and pear/ directory exists.",
                    L"Peariscope", MB_OK | MB_ICONWARNING);
    } else {
        statusText_ = "Networking ready";
    }

    return true;
}

int App::Run() {
    MSG msg = {};
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return static_cast<int>(msg.wParam);
}

// -----------------------------------------------------------------------
// Window creation
// -----------------------------------------------------------------------

bool App::CreateMainWindow(int nCmdShow) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance_;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(RGB(30, 30, 30));
    wc.lpszClassName = WINDOW_CLASS;
    RegisterClassExW(&wc);

    mainWindow_ = CreateWindowExW(
        0, WINDOW_CLASS, WINDOW_TITLE,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 800, 600,
        nullptr, nullptr, hInstance_, this
    );

    if (!mainWindow_) return false;

    ShowWindow(mainWindow_, nCmdShow);
    UpdateWindow(mainWindow_);
    return true;
}

void App::CreateControls(HWND parent) {
    btnHost_ = CreateWindowW(L"BUTTON", L"Start Hosting",
        WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
        50, 200, 200, 40, parent, (HMENU)(INT_PTR)kBtnHost, hInstance_, nullptr);

    btnConnect_ = CreateWindowW(L"BUTTON", L"Connect",
        WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
        50, 300, 350, 40, parent, (HMENU)(INT_PTR)kBtnConnect, hInstance_, nullptr);

    editCode_ = CreateWindowW(L"EDIT", L"",
        WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL | ES_LOWERCASE,
        50, 260, 350, 28, parent, nullptr, hInstance_, nullptr);
    SendMessageW(editCode_, EM_SETLIMITTEXT, 200, 0);

    btnStop_ = CreateWindowW(L"BUTTON", L"Stop",
        WS_CHILD | BS_PUSHBUTTON,
        50, 350, 200, 40, parent, (HMENU)(INT_PTR)kBtnStop, hInstance_, nullptr);
}

void App::UpdateControlVisibility() {
    bool idle = (mode_ == AppMode::Idle);
    bool hosting = (mode_ == AppMode::Hosting);

    ShowWindow(btnHost_,    idle ? SW_SHOW : SW_HIDE);
    ShowWindow(btnConnect_, idle ? SW_SHOW : SW_HIDE);
    ShowWindow(editCode_,   idle ? SW_SHOW : SW_HIDE);
    ShowWindow(btnStop_,    hosting ? SW_SHOW : SW_HIDE);
}

// -----------------------------------------------------------------------
// Message handling
// -----------------------------------------------------------------------

LRESULT CALLBACK App::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    App* app = nullptr;
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCT*>(lParam);
        app = static_cast<App*>(cs->lpCreateParams);
        SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    } else {
        app = reinterpret_cast<App*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    }
    if (app) return app->HandleMessage(hwnd, msg, wParam, lParam);
    return DefWindowProc(hwnd, msg, wParam, lParam);
}

LRESULT App::HandleMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    // In viewer mode, forward input to capture
    if (mode_ == AppMode::Viewing && inputCapture_ &&
        inputCapture_->ProcessMessage(hwnd, msg, wParam, lParam)) {
        return 0;
    }

    switch (msg) {
    case WM_DESTROY:
        KillTimer(hwnd, kTimerCapture);
        KillTimer(hwnd, kTimerFps);
        KillTimer(hwnd, kTimerCursor);
        KillTimer(hwnd, kTimerQuality);
        StopHosting();
        Disconnect();
        PostQuitMessage(0);
        return 0;

    case WM_COMMAND:
        OnCommand(hwnd, wParam);
        return 0;

    case WM_SIZE:
        OnSize(hwnd, LOWORD(lParam), HIWORD(lParam));
        return 0;

    case WM_TIMER:
        OnTimer(hwnd, wParam);
        return 0;

    case WM_PAINT:
        OnPaint(hwnd);
        return 0;
    }

    return DefWindowProc(hwnd, msg, wParam, lParam);
}

void App::OnCommand(HWND hwnd, WPARAM wParam) {
    int id = LOWORD(wParam);
    switch (id) {
    case kBtnHost:
        StartHosting();
        break;
    case kBtnConnect: {
        wchar_t buf[256] = {};
        GetWindowTextW(editCode_, buf, 256);
        char code[256];
        WideCharToMultiByte(CP_UTF8, 0, buf, -1, code, 256, nullptr, nullptr);
        if (strlen(code) > 0) {
            ConnectToHost(code);
        }
        break;
    }
    case kBtnStop:
        StopHosting();
        break;
    }
}

void App::OnSize(HWND hwnd, UINT width, UINT height) {
    if (renderer_ && width > 0 && height > 0) {
        renderer_->Resize(width, height);
    }
}

void App::OnTimer(HWND hwnd, UINT_PTR timerId) {
    if (timerId == kTimerCapture && mode_ == AppMode::Hosting) {
        OnFrameCaptured();
    } else if (timerId == kTimerFps) {
        if (mode_ == AppMode::Hosting) {
            currentFps_ = framesInSecond_;
            framesInSecond_ = 0;
            inputEventsThisSecond_ = 0;
        } else if (mode_ == AppMode::Viewing) {
            viewerFps_ = viewerFrameCount_;
            viewerFrameCount_ = 0;

            // Stale connection detection
            if (viewerFps_ == 0 && !isReconnecting_) {
                noFrameSeconds_++;
                if (noFrameSeconds_ >= 2 && noFrameSeconds_ <= 10) {
                    SendRequestIdr();
                }
                if (noFrameSeconds_ >= 15) {
                    OutputDebugStringA("[viewer] Stale connection, attempting reconnect\n");
                    AttemptReconnect();
                }
            } else {
                noFrameSeconds_ = 0;
            }
        }
        InvalidateUI();
    } else if (timerId == kTimerCursor && mode_ == AppMode::Hosting) {
        SendCursorPosition();
    } else if (timerId == kTimerQuality && mode_ == AppMode::Viewing) {
        SendQualityReport();
    }
}

void App::OnPaint(HWND hwnd) {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT rc;
    GetClientRect(hwnd, &rc);

    // Only paint custom UI when NOT in viewer mode (D3D handles viewer)
    if (mode_ != AppMode::Viewing) {
        HBRUSH bg = CreateSolidBrush(RGB(30, 30, 30));
        FillRect(hdc, &rc, bg);
        DeleteObject(bg);

        SetBkMode(hdc, TRANSPARENT);

        if (mode_ == AppMode::Idle) {
            PaintIdleUI(hdc, rc);
        } else if (mode_ == AppMode::Hosting) {
            PaintHostingUI(hdc, rc);
        }

        // Status bar at bottom
        RECT statusRc = rc;
        statusRc.top = rc.bottom - 30;
        PaintStatusBar(hdc, statusRc);
    }

    EndPaint(hwnd, &ps);
}

void App::PaintIdleUI(HDC hdc, const RECT& rc) {
    HFONT titleFont = CreateFontW(32, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT subtitleFont = CreateFontW(16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

    HFONT oldFont = (HFONT)SelectObject(hdc, titleFont);
    SetTextColor(hdc, RGB(100, 200, 80));
    RECT titleRc = {50, 50, rc.right - 50, 100};
    DrawTextW(hdc, L"Peariscope", -1, &titleRc, DT_LEFT | DT_SINGLELINE);

    SelectObject(hdc, subtitleFont);
    SetTextColor(hdc, RGB(180, 180, 180));
    RECT subRc = {50, 100, rc.right - 50, 140};
    DrawTextW(hdc, L"P2P Remote Desktop", -1, &subRc, DT_LEFT | DT_SINGLELINE);

    RECT hostLabel = {50, 180, 300, 200};
    DrawTextW(hdc, L"Share your screen:", -1, &hostLabel, DT_LEFT | DT_SINGLELINE);

    RECT connectLabel = {50, 240, 300, 260};
    DrawTextW(hdc, L"Connect to a host:", -1, &connectLabel, DT_LEFT | DT_SINGLELINE);

    SelectObject(hdc, oldFont);
    DeleteObject(titleFont);
    DeleteObject(subtitleFont);
}

void App::PaintHostingUI(HDC hdc, const RECT& rc) {
    HFONT titleFont = CreateFontW(24, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT codeFont = CreateFontW(18, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT infoFont = CreateFontW(16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

    HFONT oldFont = (HFONT)SelectObject(hdc, titleFont);
    SetTextColor(hdc, RGB(100, 200, 80));
    RECT titleRc = {50, 50, rc.right - 50, 90};
    DrawTextW(hdc, L"Hosting Active", -1, &titleRc, DT_LEFT | DT_SINGLELINE);

    // Connection code
    SelectObject(hdc, infoFont);
    SetTextColor(hdc, RGB(180, 180, 180));
    RECT codeLabel = {50, 110, rc.right - 50, 130};
    DrawTextW(hdc, L"Connection Code:", -1, &codeLabel, DT_LEFT | DT_SINGLELINE);

    if (!connectionCode_.empty()) {
        SelectObject(hdc, codeFont);
        SetTextColor(hdc, RGB(100, 200, 80));
        int len = MultiByteToWideChar(CP_UTF8, 0, connectionCode_.c_str(), -1, nullptr, 0);
        std::wstring wcode(len - 1, 0);
        MultiByteToWideChar(CP_UTF8, 0, connectionCode_.c_str(), -1, wcode.data(), len);
        RECT codeRc = {50, 140, rc.right - 50, 260};
        DrawTextW(hdc, wcode.c_str(), -1, &codeRc, DT_LEFT | DT_WORDBREAK);
    }

    // Peer count and FPS
    SelectObject(hdc, infoFont);
    SetTextColor(hdc, RGB(180, 180, 180));
    std::lock_guard<std::mutex> lock(peerMutex_);
    size_t approvedCount = connectedPeers_.size() - pendingPeerIds_.size();
    std::wstring peerText = L"Connected peers: " + std::to_wstring(approvedCount);
    RECT peerRc = {50, 270, rc.right - 50, 300};
    DrawTextW(hdc, peerText.c_str(), -1, &peerRc, DT_LEFT | DT_SINGLELINE);

    std::wstring fpsText = L"FPS: " + std::to_wstring(static_cast<int>(currentFps_));
    RECT fpsRc = {50, 300, rc.right - 50, 330};
    DrawTextW(hdc, fpsText.c_str(), -1, &fpsRc, DT_LEFT | DT_SINGLELINE);

    // PIN status
    if (!pendingPeerPin_.empty()) {
        SetTextColor(hdc, RGB(255, 180, 50));
        std::wstring pinText = L"Pending PIN approval: " +
            std::wstring(pendingPeerPin_.begin(), pendingPeerPin_.end());
        RECT pinRc = {50, 340, rc.right - 50, 370};
        DrawTextW(hdc, pinText.c_str(), -1, &pinRc, DT_LEFT | DT_SINGLELINE);
    }

    SelectObject(hdc, oldFont);
    DeleteObject(titleFont);
    DeleteObject(codeFont);
    DeleteObject(infoFont);
}

void App::PaintStatusBar(HDC hdc, const RECT& rc) {
    HBRUSH barBg = CreateSolidBrush(RGB(20, 20, 20));
    FillRect(hdc, &rc, barBg);
    DeleteObject(barBg);

    HFONT font = CreateFontW(14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    HFONT oldFont = (HFONT)SelectObject(hdc, font);
    SetTextColor(hdc, RGB(140, 140, 140));

    int len = MultiByteToWideChar(CP_UTF8, 0, statusText_.c_str(), -1, nullptr, 0);
    std::wstring wstatus(len - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, statusText_.c_str(), -1, wstatus.data(), len);

    RECT textRc = rc;
    textRc.left += 10;
    DrawTextW(hdc, wstatus.c_str(), -1, &textRc, DT_LEFT | DT_SINGLELINE | DT_VCENTER);

    SelectObject(hdc, oldFont);
    DeleteObject(font);
}

void App::InvalidateUI() {
    if (mainWindow_) InvalidateRect(mainWindow_, nullptr, FALSE);
}

// -----------------------------------------------------------------------
// IPC callbacks
// -----------------------------------------------------------------------

void App::SetupIpcCallbacks() {
    ipcBridge_->onHostingStarted = [this](const HostingStartedEvent& e) {
        OnHostingStarted(e.publicKeyHex, e.connectionCode);
    };
    ipcBridge_->onHostingStopped = [this]() { OnHostingStopped(); };
    ipcBridge_->onPeerConnected = [this](const PeerConnectedEvent& e) {
        OnPeerConnected(e.peerKeyHex, e.streamId);
    };
    ipcBridge_->onPeerDisconnected = [this](const PeerDisconnectedEvent& e) {
        OnPeerDisconnected(e.peerKeyHex);
    };
    ipcBridge_->onStreamData = [this](const StreamDataEvent& e) {
        OnStreamData(e.streamId, e.channel, e.data.data(), e.data.size());
    };
    ipcBridge_->onConnectionFailed = [this](const ConnectionFailedEvent& e) {
        OnConnectionFailed(e.code, e.reason);
    };
    ipcBridge_->onConnectionEstablished = [this](const ConnectionEstablishedEvent& e) {
        OutputDebugStringA(("[pear] Connection established: " + e.peerKeyHex.substr(0, 16) + "\n").c_str());
    };
    ipcBridge_->onLog = [this](const std::string& msg) {
        OutputDebugStringA(("[pear] " + msg + "\n").c_str());
    };
    ipcBridge_->onError = [this](const std::string& msg) {
        lastError_ = msg;
        statusText_ = "Error: " + msg;
        PostMessage(mainWindow_, WM_PAINT, 0, 0);
    };
    ipcBridge_->onLookupResult = [this](const LookupResultEvent& e) {
        OutputDebugStringA(("[pear] Lookup result: " + e.code + " online=" +
                           (e.online ? "true" : "false") + "\n").c_str());
    };
}

void App::OnHostingStarted(const std::string& publicKeyHex,
                           const std::string& connectionCode) {
    publicKeyHex_ = publicKeyHex;
    connectionCode_ = connectionCode;
    statusText_ = "Hosting active — waiting for peers";
    PostMessage(mainWindow_, WM_PAINT, 0, 0);
}

void App::OnHostingStopped() {
    mode_ = AppMode::Idle;
    connectionCode_.clear();
    statusText_ = "Hosting stopped";
    PostMessage(mainWindow_, WM_PAINT, 0, 0);
    UpdateControlVisibility();
}

void App::OnPeerConnected(const std::string& peerKey, uint32_t streamId) {
    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        if (peerKeySet_.count(peerKey)) return;
        peerKeySet_.insert(peerKey);
        connectedPeers_.push_back({peerKey, "", streamId});
    }

    if (mode_ == AppMode::Hosting) {
        // PIN verification
        if (requirePin_ && !pinCode_.empty()) {
            pendingPeerIds_.insert(peerKey);
            pendingPeerPin_ = pinCode_;
            pendingPeerKeyHex_ = peerKey;
            SendPinChallenge(peerKey, streamId);
            statusText_ = "Peer connecting — awaiting PIN verification";
        } else {
            // Start streaming immediately
            if (!isCaptureRunning_) {
                StartCapture();
            }
            SendCodecNegotiation(streamId);
            SendDisplayList(streamId);
            ForceKeyframe();

            // Force keyframes at 0.5s, 1.0s, 2.0s after connect
            // Use PostMessage + timer trick (simplified: force at next few captures)
            // We'll set a counter and force keyframes for the next ~120 frames
        }
        statusText_ = "Peer connected";
    } else if (mode_ == AppMode::Viewing) {
        isReconnecting_ = false;
        reconnectAttempts_ = 0;
        noFrameSeconds_ = 0;
        statusText_ = "Connected to host";
    }

    PostMessage(mainWindow_, WM_PAINT, 0, 0);
}

void App::OnPeerDisconnected(const std::string& peerKey) {
    bool wasViewing = (mode_ == AppMode::Viewing);
    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        peerKeySet_.erase(peerKey);
        connectedPeers_.erase(
            std::remove_if(connectedPeers_.begin(), connectedPeers_.end(),
                           [&](const PeerState& p) { return p.peerKeyHex == peerKey; }),
            connectedPeers_.end());

        // Clear pending PIN if this was the challenged peer
        if (pendingPeerIds_.count(peerKey)) {
            pendingPeerIds_.erase(peerKey);
            if (pendingPeerKeyHex_ == peerKey) {
                pendingPeerPin_.clear();
                pendingPeerKeyHex_.clear();
            }
        }
    }

    if (mode_ == AppMode::Hosting) {
        // Stop capture when no approved peers remain
        std::lock_guard<std::mutex> lock(peerMutex_);
        bool hasApprovedPeers = false;
        for (const auto& p : connectedPeers_) {
            if (!pendingPeerIds_.count(p.peerKeyHex)) {
                hasApprovedPeers = true;
                break;
            }
        }
        if (!hasApprovedPeers && isCaptureRunning_) {
            StopCapture();
        }
    }

    statusText_ = "Peer disconnected";
    PostMessage(mainWindow_, WM_PAINT, 0, 0);

    // Auto-reconnect in viewer mode
    if (wasViewing && connectedPeers_.empty()) {
        AttemptReconnect();
    }
}

void App::OnStreamData(uint32_t streamId, uint8_t channel,
                       const uint8_t* data, size_t size) {
    switch (channel) {
    case 0: OnVideoReceived(streamId, data, size); break;
    case 1: OnInputReceived(streamId, data, size); break;
    case 2:
        if (mode_ == AppMode::Hosting) {
            OnControlReceived(streamId, data, size);
        } else if (mode_ == AppMode::Viewing) {
            OnViewerControlReceived(streamId, data, size);
        }
        break;
    }
}

void App::OnConnectionFailed(const std::string& code,
                             const std::string& reason) {
    if (isReconnecting_) {
        // Don't reset mode during reconnection attempts
        return;
    }
    mode_ = AppMode::Idle;
    statusText_ = "Connection failed: " + reason;
    UpdateControlVisibility();
    PostMessage(mainWindow_, WM_PAINT, 0, 0);
}

// -----------------------------------------------------------------------
// Mode transitions
// -----------------------------------------------------------------------

void App::StartHosting() {
    if (mode_ != AppMode::Idle) return;

    mode_ = AppMode::Hosting;
    statusText_ = "Starting host...";
    UpdateControlVisibility();
    InvalidateUI();

    // Enumerate displays
    RefreshDisplayList();

    // Initialize renderer (needed for D3D device)
    renderer_ = std::make_unique<D3DRenderer>();
    UINT captureW = 1920, captureH = 1080;
    if (!availableDisplays_.empty()) {
        captureW = availableDisplays_[selectedDisplayIndex_].width;
        captureH = availableDisplays_[selectedDisplayIndex_].height;
    }
    if (!renderer_->Initialize(mainWindow_, captureW, captureH)) {
        statusText_ = "Failed to initialize renderer";
        mode_ = AppMode::Idle;
        UpdateControlVisibility();
        return;
    }

    // Input injector uses display dimensions
    inputInjector_ = std::make_unique<InputInjector>(captureW, captureH);

    // Start networking — capture starts when first peer connects (lazy)
    ipcBridge_->StartHosting();

    // Start timers
    SetTimer(mainWindow_, kTimerFps, 1000, nullptr);
    SetTimer(mainWindow_, kTimerCursor, kCursorIntervalMs, nullptr);
}

void App::StopHosting() {
    if (mode_ != AppMode::Hosting) return;

    KillTimer(mainWindow_, kTimerCapture);
    KillTimer(mainWindow_, kTimerFps);
    KillTimer(mainWindow_, kTimerCursor);

    ipcBridge_->StopHosting();

    StopCapture();
    inputInjector_.reset();
    renderer_.reset();

    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        connectedPeers_.clear();
        peerKeySet_.clear();
    }
    pendingPeerIds_.clear();
    pendingPeerPin_.clear();
    pendingPeerKeyHex_.clear();

    mode_ = AppMode::Idle;
    connectionCode_.clear();
    statusText_ = "Ready";
    UpdateControlVisibility();
    InvalidateUI();
}

void App::ConnectToHost(const std::string& code) {
    if (mode_ != AppMode::Idle && mode_ != AppMode::Viewing) return;

    mode_ = AppMode::Viewing;
    lastConnectCode_ = code;
    statusText_ = "Connecting...";
    UpdateControlVisibility();
    InvalidateUI();

    // Restart worklet if dead
    if (!ipcBridge_->IsAlive()) {
        ipcBridge_->Stop();
        ipcBridge_->Start();
    }

    if (!renderer_) {
        renderer_ = std::make_unique<D3DRenderer>();
        if (!renderer_->Initialize(mainWindow_, 1920, 1080)) {
            statusText_ = "Failed to initialize renderer";
            mode_ = AppMode::Idle;
            UpdateControlVisibility();
            return;
        }
    }

    if (!decoder_) {
        decoder_ = std::make_unique<MfDecoder>();
        if (!decoder_->Initialize(renderer_->GetDevice(), 1920, 1080)) {
            statusText_ = "Failed to initialize decoder";
            renderer_.reset();
            mode_ = AppMode::Idle;
            UpdateControlVisibility();
            return;
        }
        decoder_->SetCallback([this](ComPtr<ID3D11Texture2D> texture, UINT64 timestamp) {
            if (renderer_) renderer_->Present(texture.Get());
            viewerFrameCount_++;
        });
    }

    if (!inputCapture_) {
        inputCapture_ = std::make_unique<InputCapture>();
        inputCapture_->Start(mainWindow_);
        inputCapture_->SetCallback([this](const InputCapture::InputEvent& event) {
            OnLocalInput(event);
        });
    }

    // Start FPS and quality timers
    SetTimer(mainWindow_, kTimerFps, 1000, nullptr);
    SetTimer(mainWindow_, kTimerQuality, kQualityIntervalMs, nullptr);

    ipcBridge_->ConnectToPeer(code);
}

void App::Disconnect() {
    if (mode_ != AppMode::Viewing) return;

    isReconnecting_ = false;
    KillTimer(mainWindow_, kTimerFps);
    KillTimer(mainWindow_, kTimerQuality);

    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        for (auto& peer : connectedPeers_)
            ipcBridge_->Disconnect(peer.peerKeyHex);
        connectedPeers_.clear();
        peerKeySet_.clear();
    }

    inputCapture_.reset();
    decoder_.reset();
    renderer_.reset();

    mode_ = AppMode::Idle;
    viewerPendingPin_.clear();
    statusText_ = "Disconnected";
    UpdateControlVisibility();
    InvalidateUI();
}

// -----------------------------------------------------------------------
// Host pipeline
// -----------------------------------------------------------------------

void App::StartCapture() {
    if (isCaptureRunning_) return;
    if (!renderer_) return;

    UINT captureW = 1920, captureH = 1080;
    if (!availableDisplays_.empty()) {
        captureW = availableDisplays_[selectedDisplayIndex_].width;
        captureH = availableDisplays_[selectedDisplayIndex_].height;
    }

    capture_ = std::make_unique<DxgiCapture>();
    if (!capture_->Initialize(renderer_->GetDevice(), selectedDisplayIndex_)) {
        statusText_ = "Failed to initialize screen capture";
        return;
    }

    encoder_ = std::make_unique<MfEncoder>();
    if (!encoder_->Initialize(renderer_->GetDevice(),
                               capture_->GetWidth(), capture_->GetHeight())) {
        statusText_ = "Failed to initialize encoder";
        capture_.reset();
        return;
    }

    encoder_->SetCallback([this](const uint8_t* data, size_t size, bool isKeyframe) {
        OnEncodedFrame(data, size, isKeyframe);
    });

    isCaptureRunning_ = true;
    frameCount_ = 0;
    SetTimer(mainWindow_, kTimerCapture, kCaptureIntervalMs, nullptr);
    OutputDebugStringA("[host] Capture started\n");
}

void App::StopCapture() {
    if (!isCaptureRunning_) return;
    KillTimer(mainWindow_, kTimerCapture);
    encoder_.reset();
    capture_.reset();
    isCaptureRunning_ = false;
    OutputDebugStringA("[host] Capture stopped\n");
}

void App::OnFrameCaptured() {
    if (!capture_ || !encoder_) return;

    if (capture_->CaptureFrame()) {
        auto* texture = capture_->GetFrameTexture();
        if (texture) {
            encoder_->Encode(texture, frameCount_);
            framesInSecond_++;

            // Periodic keyframe every 2 seconds (120 frames at 60fps)
            if (frameCount_ > 0 && frameCount_ % 120 == 0) {
                ForceKeyframe();
            }

            // Frame timestamp every 30 frames
            if (frameCount_ % 30 == 0) {
                SendFrameTimestamp();
            }

            frameCount_++;
        }
        capture_->ReleaseFrame();
    }
}

void App::OnEncodedFrame(const uint8_t* data, size_t size, bool isKeyframe) {
    std::lock_guard<std::mutex> lock(peerMutex_);
    for (auto& peer : connectedPeers_) {
        // Don't send video to peers pending PIN verification
        if (pendingPeerIds_.count(peer.peerKeyHex)) continue;

        ipcBridge_->SendStreamData(peer.streamId,
            static_cast<uint8_t>(StreamChannel::Video), data, size);
    }
}

void App::ForceKeyframe() {
    if (encoder_) encoder_->ForceKeyframe();
}

void App::OnInputReceived(uint32_t streamId, const uint8_t* data, size_t size) {
    // Rate limit
    if (inputEventsThisSecond_ >= kMaxInputEventsPerSecond) return;
    inputEventsThisSecond_++;

    // Don't inject input from pending (unverified) peers
    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        for (const auto& p : connectedPeers_) {
            if (p.streamId == streamId && pendingPeerIds_.count(p.peerKeyHex)) {
                return;
            }
        }
    }

    DeserializeAndInjectInput(data, size);
}

// -----------------------------------------------------------------------
// Host control messages
// -----------------------------------------------------------------------

void App::OnControlReceived(uint32_t streamId, const uint8_t* data, size_t size) {
    peariscope::ControlMessage control;
    if (!control.ParseFromArray(data, static_cast<int>(size))) return;

    switch (control.msg_case()) {
    case peariscope::ControlMessage::kRequestIdr:
        ForceKeyframe();
        break;

    case peariscope::ControlMessage::kQualityReport: {
        // TODO: Feed to adaptive quality system
        auto& report = control.quality_report();
        OutputDebugStringA(("[host] Quality report: fps=" +
            std::to_string(report.fps()) + " loss=" +
            std::to_string(report.packet_loss()) + "\n").c_str());
        break;
    }

    case peariscope::ControlMessage::kClipboard: {
        // TODO: Apply to Windows clipboard
        auto& clip = control.clipboard();
        OutputDebugStringA(("[host] Clipboard received: " +
            std::to_string(clip.text().size()) + " chars\n").c_str());
        break;
    }

    case peariscope::ControlMessage::kSwitchDisplay: {
        auto& sw = control.switch_display();
        UINT newIndex = sw.display_id();
        if (newIndex < availableDisplays_.size() && newIndex != selectedDisplayIndex_) {
            selectedDisplayIndex_ = newIndex;
            // Restart capture with new display
            if (isCaptureRunning_) {
                StopCapture();
                StartCapture();
                // Send updated display list
                std::lock_guard<std::mutex> lock(peerMutex_);
                for (const auto& p : connectedPeers_) {
                    SendDisplayList(p.streamId);
                }
            }
        }
        break;
    }

    case peariscope::ControlMessage::kPeerChallengeResponse: {
        auto& resp = control.peer_challenge_response();
        if (resp.pin() == pinCode_) {
            RespondToPeer(true);
        } else {
            RespondToPeer(false);
        }
        break;
    }

    default:
        break;
    }
}

void App::SendCursorPosition() {
    POINT pt;
    if (!GetCursorPos(&pt)) return;

    // Get the active display dimensions
    UINT dispW = 1920, dispH = 1080;
    if (capture_) {
        dispW = capture_->GetWidth();
        dispH = capture_->GetHeight();
    }

    // Normalize to 0-1 range relative to display
    float nx = static_cast<float>(pt.x) / static_cast<float>(dispW);
    float ny = static_cast<float>(pt.y) / static_cast<float>(dispH);
    nx = (std::max)(0.0f, (std::min)(1.0f, nx));
    ny = (std::max)(0.0f, (std::min)(1.0f, ny));

    // Only send if position changed significantly (>0.03%)
    float dx = nx - lastCursorX_;
    float dy = ny - lastCursorY_;
    if (dx * dx + dy * dy < 0.0000001f) return;

    lastCursorX_ = nx;
    lastCursorY_ = ny;

    peariscope::ControlMessage control;
    auto* cursor = control.mutable_cursor_position();
    cursor->set_x(nx);
    cursor->set_y(ny);

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    SendControlDataToAll(data);
}

void App::SendCodecNegotiation(uint32_t streamId) {
    peariscope::ControlMessage control;
    auto* codec = control.mutable_codec_negotiation();
    codec->add_supported_codecs(peariscope::CODEC_H264);
    // TODO: Check for HEVC encoder support and add CODEC_H265
    codec->set_selected_codec(peariscope::CODEC_H264);

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    SendControlData(data, streamId);
}

void App::SendDisplayList(uint32_t streamId) {
    peariscope::ControlMessage control;
    auto* displayList = control.mutable_display_list();

    for (size_t i = 0; i < availableDisplays_.size(); ++i) {
        auto* info = displayList->add_displays();
        info->set_display_id(static_cast<uint32_t>(i));
        info->set_width(availableDisplays_[i].width);
        info->set_height(availableDisplays_[i].height);
        // Convert wstring name to UTF8
        int len = WideCharToMultiByte(CP_UTF8, 0,
            availableDisplays_[i].name.c_str(), -1, nullptr, 0, nullptr, nullptr);
        std::string name(len - 1, 0);
        WideCharToMultiByte(CP_UTF8, 0,
            availableDisplays_[i].name.c_str(), -1, name.data(), len, nullptr, nullptr);
        info->set_name(name);
        info->set_is_active(i == selectedDisplayIndex_);
    }

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    SendControlData(data, streamId);
}

void App::SendFrameTimestamp() {
    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();

    peariscope::ControlMessage control;
    auto* ts = control.mutable_frame_timestamp();
    ts->set_capture_time_ms(static_cast<uint64_t>(ms));
    ts->set_frame_id(frameCount_);

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    SendControlDataToAll(data);
}

void App::SendControlData(const std::vector<uint8_t>& data, uint32_t streamId) {
    ipcBridge_->SendStreamData(streamId,
        static_cast<uint8_t>(StreamChannel::Control),
        data.data(), data.size());
}

void App::SendControlDataToAll(const std::vector<uint8_t>& data) {
    std::lock_guard<std::mutex> lock(peerMutex_);
    for (const auto& peer : connectedPeers_) {
        if (pendingPeerIds_.count(peer.peerKeyHex)) continue;
        SendControlData(data, peer.streamId);
    }
}

// -----------------------------------------------------------------------
// PIN verification
// -----------------------------------------------------------------------

void App::SendPinChallenge(const std::string& peerKeyHex, uint32_t streamId) {
    peariscope::ControlMessage control;
    auto* challenge = control.mutable_peer_challenge();
    challenge->set_pin(pinCode_);
    // Convert hex string to bytes for peer_key
    std::string peerKeyBytes;
    for (size_t i = 0; i + 1 < peerKeyHex.size(); i += 2) {
        uint8_t byte = static_cast<uint8_t>(
            std::stoi(peerKeyHex.substr(i, 2), nullptr, 16));
        peerKeyBytes.push_back(static_cast<char>(byte));
    }
    challenge->set_peer_key(peerKeyBytes);

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    SendControlData(data, streamId);

    OutputDebugStringA(("[host] Sent PIN challenge to peer: " +
        peerKeyHex.substr(0, 16) + "\n").c_str());
}

void App::RespondToPeer(bool accepted) {
    if (pendingPeerKeyHex_.empty()) return;

    std::string peerKey = pendingPeerKeyHex_;
    pendingPeerPin_.clear();
    pendingPeerKeyHex_.clear();
    pendingPeerIds_.erase(peerKey);

    if (accepted) {
        // Find the peer's streamId and send confirmation
        uint32_t streamId = 0;
        {
            std::lock_guard<std::mutex> lock(peerMutex_);
            for (const auto& p : connectedPeers_) {
                if (p.peerKeyHex == peerKey) {
                    streamId = p.streamId;
                    break;
                }
            }
        }

        if (streamId > 0) {
            // Send acceptance
            peariscope::ControlMessage control;
            auto* resp = control.mutable_peer_challenge_response();
            resp->set_pin(pinCode_);
            resp->set_accepted(true);
            std::string serialized;
            if (control.SerializeToString(&serialized)) {
                std::vector<uint8_t> data(serialized.begin(), serialized.end());
                SendControlData(data, streamId);
            }

            // Start streaming
            if (!isCaptureRunning_) StartCapture();
            SendCodecNegotiation(streamId);
            SendDisplayList(streamId);
            ForceKeyframe();
        }
        OutputDebugStringA("[host] Peer approved\n");
    } else {
        // Disconnect rejected peer
        ipcBridge_->Disconnect(peerKey);
        OutputDebugStringA("[host] Peer rejected\n");
    }

    PostMessage(mainWindow_, WM_PAINT, 0, 0);
}

// -----------------------------------------------------------------------
// Viewer pipeline
// -----------------------------------------------------------------------

void App::OnVideoReceived(uint32_t streamId, const uint8_t* data, size_t size) {
    if (decoder_ && size > 0) {
        decoder_->Decode(data, static_cast<DWORD>(size));
    }
}

void App::OnViewerControlReceived(uint32_t streamId, const uint8_t* data, size_t size) {
    peariscope::ControlMessage control;
    if (!control.ParseFromArray(data, static_cast<int>(size))) return;

    switch (control.msg_case()) {
    case peariscope::ControlMessage::kCodecNegotiation: {
        auto& codec = control.codec_negotiation();
        OutputDebugStringA(("[viewer] Codec negotiation: selected=" +
            std::to_string(codec.selected_codec()) + "\n").c_str());
        // TODO: Switch decoder if H.265 selected and supported
        break;
    }

    case peariscope::ControlMessage::kCursorPosition: {
        auto& cursor = control.cursor_position();
        remoteCursorX_ = cursor.x();
        remoteCursorY_ = cursor.y();
        // TODO: Render cursor sprite at this position
        break;
    }

    case peariscope::ControlMessage::kFrameTimestamp: {
        auto& ts = control.frame_timestamp();
        auto now = std::chrono::system_clock::now();
        auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
        auto latency = nowMs - static_cast<int64_t>(ts.capture_time_ms());
        // Store for quality reports
        (void)latency;
        break;
    }

    case peariscope::ControlMessage::kDisplayList: {
        auto& displays = control.display_list();
        OutputDebugStringA(("[viewer] Display list: " +
            std::to_string(displays.displays_size()) + " displays\n").c_str());
        // TODO: Populate display selection UI
        break;
    }

    case peariscope::ControlMessage::kPeerChallenge: {
        auto& challenge = control.peer_challenge();
        viewerPendingPin_ = challenge.pin();
        statusText_ = "PIN: " + viewerPendingPin_;
        PostMessage(mainWindow_, WM_PAINT, 0, 0);
        // TODO: Show PIN entry dialog
        break;
    }

    case peariscope::ControlMessage::kPeerChallengeResponse: {
        auto& resp = control.peer_challenge_response();
        if (resp.accepted()) {
            viewerPendingPin_.clear();
            statusText_ = "Connected to host";
            PostMessage(mainWindow_, WM_PAINT, 0, 0);
        }
        break;
    }

    default:
        break;
    }
}

void App::OnLocalInput(const InputCapture::InputEvent& event) {
    auto serialized = SerializeInputEvent(event);
    if (serialized.empty()) return;

    std::lock_guard<std::mutex> lock(peerMutex_);
    for (auto& peer : connectedPeers_) {
        ipcBridge_->SendStreamData(peer.streamId,
            static_cast<uint8_t>(StreamChannel::Input),
            serialized.data(), serialized.size());
    }
}

void App::SendQualityReport() {
    peariscope::ControlMessage control;
    auto* report = control.mutable_quality_report();
    report->set_fps(viewerFps_);
    report->set_rtt_ms(0);
    report->set_packet_loss(0.0f);
    report->set_bitrate_kbps(0);

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());

    std::lock_guard<std::mutex> lock(peerMutex_);
    for (const auto& peer : connectedPeers_) {
        SendControlData(data, peer.streamId);
    }
}

void App::SendRequestIdr() {
    peariscope::ControlMessage control;
    control.mutable_request_idr();

    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());

    std::lock_guard<std::mutex> lock(peerMutex_);
    for (const auto& peer : connectedPeers_) {
        SendControlData(data, peer.streamId);
    }
}

void App::AttemptReconnect() {
    if (isReconnecting_ || lastConnectCode_.empty()) return;
    if (mode_ != AppMode::Viewing) return;

    reconnectAttempts_++;
    if (reconnectAttempts_ > 5) {
        statusText_ = "Connection lost";
        isReconnecting_ = false;
        // Return to idle
        Disconnect();
        return;
    }

    isReconnecting_ = true;
    statusText_ = "Reconnecting (attempt " + std::to_string(reconnectAttempts_) + "/5)...";
    PostMessage(mainWindow_, WM_PAINT, 0, 0);

    // Restart worklet if dead
    if (!ipcBridge_->IsAlive()) {
        ipcBridge_->Stop();
        ipcBridge_->Start();
    }

    ipcBridge_->ConnectToPeer(lastConnectCode_);
}

// -----------------------------------------------------------------------
// Display management
// -----------------------------------------------------------------------

void App::RefreshDisplayList() {
    availableDisplays_ = DxgiCapture::EnumerateDisplays();
    if (selectedDisplayIndex_ >= availableDisplays_.size()) {
        selectedDisplayIndex_ = 0;
    }
}

// -----------------------------------------------------------------------
// Protobuf serialization
// -----------------------------------------------------------------------

std::vector<uint8_t> App::SerializeInputEvent(const InputCapture::InputEvent& event) {
    peariscope::InputEvent pb;
    pb.set_timestamp_ms(static_cast<uint32_t>(GetTickCount64() & 0xFFFFFFFF));

    switch (event.type) {
    case InputCapture::InputEvent::KEY: {
        auto* key = pb.mutable_key();
        key->set_keycode(event.keycode);
        key->set_modifiers(event.modifiers);
        key->set_pressed(event.pressed);
        break;
    }
    case InputCapture::InputEvent::MOUSE_MOVE: {
        auto* move = pb.mutable_mouse_move();
        move->set_x(event.x);
        move->set_y(event.y);
        break;
    }
    case InputCapture::InputEvent::MOUSE_BUTTON: {
        auto* btn = pb.mutable_mouse_button();
        btn->set_button(event.button);
        btn->set_pressed(event.pressed);
        btn->set_x(event.x);
        btn->set_y(event.y);
        break;
    }
    case InputCapture::InputEvent::SCROLL: {
        auto* scroll = pb.mutable_scroll();
        scroll->set_delta_x(event.scrollDeltaX);
        scroll->set_delta_y(event.scrollDeltaY);
        break;
    }
    }

    std::string serialized;
    if (!pb.SerializeToString(&serialized)) return {};
    return {serialized.begin(), serialized.end()};
}

void App::DeserializeAndInjectInput(const uint8_t* data, size_t size) {
    if (!inputInjector_) return;

    peariscope::InputEvent pb;
    if (!pb.ParseFromArray(data, static_cast<int>(size))) return;

    switch (pb.event_case()) {
    case peariscope::InputEvent::kKey: {
        auto& key = pb.key();
        uint32_t keycode = key.keycode();
        bool isVirtualKey = (key.modifiers() & 0x80000000) != 0;
        if (isVirtualKey) {
            inputInjector_->InjectKey(keycode, key.modifiers() & ~0x80000000u, key.pressed());
        } else {
            SHORT vk = VkKeyScanW(static_cast<WCHAR>(keycode));
            if (vk != -1)
                inputInjector_->InjectKey(LOBYTE(vk), key.modifiers(), key.pressed());
        }
        break;
    }
    case peariscope::InputEvent::kMouseMove:
        inputInjector_->InjectMouseMove(pb.mouse_move().x(), pb.mouse_move().y());
        break;
    case peariscope::InputEvent::kMouseButton:
        inputInjector_->InjectMouseButton(pb.mouse_button().button(),
                                           pb.mouse_button().pressed(),
                                           pb.mouse_button().x(),
                                           pb.mouse_button().y());
        break;
    case peariscope::InputEvent::kScroll:
        inputInjector_->InjectScroll(pb.scroll().delta_x(), pb.scroll().delta_y());
        break;
    default:
        break;
    }
}

} // namespace peariscope
