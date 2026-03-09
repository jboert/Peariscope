#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <memory>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <unordered_map>
#include <unordered_set>
#include <cstdint>
#include <functional>

#include "capture/DxgiCapture.h"
#include "video/MfEncoder.h"
#include "video/MfDecoder.h"
#include "video/D3DRenderer.h"
#include "input/InputCapture.h"
#include "input/InputInjector.h"
#include "networking/IpcBridge.h"
#include "auth/KeyManager.h"

namespace peariscope {

/// Stream data channel identifiers matching the Pear protocol.
enum class StreamChannel : uint8_t {
    Video   = 0,
    Input   = 1,
    Control = 2,
};

/// Application mode.
enum class AppMode {
    Idle,
    Hosting,
    Viewing,
};

/// Tracks a connected peer.
struct PeerState {
    std::string peerKeyHex;
    std::string name;
    uint32_t    streamId = 0;
};

/// Main application class for Peariscope on Windows.
///
/// Manages the full lifecycle of host and viewer sessions using a single
/// Win32 window.  In host mode the window shows a connection code and
/// peer count.  In viewer mode the window becomes the video display with
/// input capture active.
class App {
public:
    explicit App(HINSTANCE hInstance);
    ~App();

    App(const App&) = delete;
    App& operator=(const App&) = delete;

    /// Initialise COM, create the main window, and connect the IPC bridge.
    bool Initialize(int nCmdShow);

    /// Enter the Win32 message loop.  Returns the exit code.
    int Run();

private:
    // ----------------------------------------------------------------
    // Win32 window handling
    // ----------------------------------------------------------------
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);

    bool CreateMainWindow(int nCmdShow);

    void OnPaint(HWND hwnd);
    void OnCommand(HWND hwnd, WPARAM wParam);
    void OnSize(HWND hwnd, UINT width, UINT height);
    void OnTimer(HWND hwnd, UINT_PTR timerId);

    void InvalidateUI();

    // ----------------------------------------------------------------
    // Mode transitions
    // ----------------------------------------------------------------
    void StartHosting();
    void StopHosting();
    void ConnectToHost(const std::string& code);
    void Disconnect();

    // ----------------------------------------------------------------
    // IPC bridge callbacks (called on the IPC read thread)
    // ----------------------------------------------------------------
    void SetupIpcCallbacks();
    void OnHostingStarted(const std::string& publicKeyHex,
                          const std::string& connectionCode);
    void OnHostingStopped();
    void OnPeerConnected(const std::string& peerKey, uint32_t streamId);
    void OnPeerDisconnected(const std::string& peerKey);
    void OnStreamData(uint32_t streamId, uint8_t channel,
                      const uint8_t* data, size_t size);
    void OnConnectionFailed(const std::string& code,
                            const std::string& reason);

    // ----------------------------------------------------------------
    // Host pipeline helpers
    // ----------------------------------------------------------------
    void OnFrameCaptured();
    void OnEncodedFrame(const uint8_t* data, size_t size, bool isKeyframe);
    void OnInputReceived(uint32_t streamId, const uint8_t* data, size_t size);
    void OnControlReceived(uint32_t streamId, const uint8_t* data, size_t size);
    void ForceKeyframe();
    void StartCapture();
    void StopCapture();

    // Host control message senders
    void SendCursorPosition();
    void SendCodecNegotiation(uint32_t streamId);
    void SendDisplayList(uint32_t streamId);
    void SendFrameTimestamp();
    void SendControlData(const std::vector<uint8_t>& data, uint32_t streamId);
    void SendControlDataToAll(const std::vector<uint8_t>& data);

    // PIN verification
    void SendPinChallenge(const std::string& peerKeyHex, uint32_t streamId);
    void RespondToPeer(bool accepted);

    // ----------------------------------------------------------------
    // Viewer pipeline helpers
    // ----------------------------------------------------------------
    void OnVideoReceived(uint32_t streamId, const uint8_t* data, size_t size);
    void OnViewerControlReceived(uint32_t streamId, const uint8_t* data, size_t size);
    void OnLocalInput(const InputCapture::InputEvent& event);
    void SendQualityReport();
    void SendRequestIdr();
    void AttemptReconnect();

    // ----------------------------------------------------------------
    // Protobuf serialisation helpers
    // ----------------------------------------------------------------
    static std::vector<uint8_t> SerializeInputEvent(
        const InputCapture::InputEvent& event);
    void DeserializeAndInjectInput(const uint8_t* data, size_t size);

    // ----------------------------------------------------------------
    // UI painting (GDI)
    // ----------------------------------------------------------------
    void PaintIdleUI(HDC hdc, const RECT& rc);
    void PaintHostingUI(HDC hdc, const RECT& rc);
    void PaintStatusBar(HDC hdc, const RECT& rc);

    // ----------------------------------------------------------------
    // Display management
    // ----------------------------------------------------------------
    void RefreshDisplayList();

    // ----------------------------------------------------------------
    // UI button hit-testing
    // ----------------------------------------------------------------
    static constexpr int kBtnHost    = 1001;
    static constexpr int kBtnConnect = 1002;
    static constexpr int kBtnStop    = 1003;

    HWND btnHost_    = nullptr;
    HWND btnConnect_ = nullptr;
    HWND btnStop_    = nullptr;
    HWND editCode_   = nullptr;  // code entry field for viewer connect

    void CreateControls(HWND parent);
    void UpdateControlVisibility();

    // ----------------------------------------------------------------
    // Timer IDs
    // ----------------------------------------------------------------
    static constexpr UINT_PTR kTimerCapture  = 1;
    static constexpr UINT_PTR kTimerFps      = 2;
    static constexpr UINT_PTR kTimerCursor   = 3;
    static constexpr UINT_PTR kTimerQuality  = 4;
    static constexpr UINT    kCaptureIntervalMs = 16;  // ~60 fps
    static constexpr UINT    kCursorIntervalMs  = 16;  // ~60 Hz cursor updates
    static constexpr UINT    kQualityIntervalMs = 2000; // quality reports every 2s

    // ----------------------------------------------------------------
    // Instance state
    // ----------------------------------------------------------------
    HINSTANCE hInstance_;
    HWND      mainWindow_ = nullptr;

    AppMode mode_ = AppMode::Idle;

    // Components
    std::unique_ptr<D3DRenderer>   renderer_;
    std::unique_ptr<DxgiCapture>   capture_;
    std::unique_ptr<MfEncoder>     encoder_;
    std::unique_ptr<MfDecoder>     decoder_;
    std::unique_ptr<InputCapture>  inputCapture_;
    std::unique_ptr<InputInjector> inputInjector_;
    std::unique_ptr<IpcBridge>     ipcBridge_;
    std::unique_ptr<KeyManager>    keyManager_;

    // Host state
    std::string connectionCode_;
    std::string publicKeyHex_;
    uint32_t    frameCount_     = 0;
    uint32_t    framesInSecond_ = 0;
    double      currentFps_     = 0.0;
    bool        isCaptureRunning_ = false;

    // Cursor tracking (host)
    float lastCursorX_ = -1.0f;
    float lastCursorY_ = -1.0f;

    // Input rate limiting (host)
    uint32_t inputEventsThisSecond_ = 0;
    static constexpr uint32_t kMaxInputEventsPerSecond = 500;

    // PIN verification (host)
    std::string pendingPeerPin_;
    std::string pendingPeerKeyHex_;
    std::unordered_set<std::string> pendingPeerIds_;
    bool requirePin_ = false;
    std::string pinCode_;

    // Display management
    std::vector<DisplayInfo> availableDisplays_;
    UINT selectedDisplayIndex_ = 0;

    // Peer tracking (guarded by peerMutex_)
    std::mutex                          peerMutex_;
    std::vector<PeerState>              connectedPeers_;
    std::unordered_set<std::string>     peerKeySet_;

    // Connection state
    std::string statusText_ = "Ready";
    std::string lastError_;

    // Viewer state
    bool inputCaptureActive_ = false;
    std::string lastConnectCode_;  // for reconnection
    bool isReconnecting_ = false;
    int  reconnectAttempts_ = 0;

    // Viewer stats
    uint32_t viewerFps_ = 0;
    uint32_t viewerFrameCount_ = 0;
    uint32_t noFrameSeconds_ = 0;

    // Remote cursor position (viewer, from host CursorPosition messages)
    float remoteCursorX_ = 0.5f;
    float remoteCursorY_ = 0.5f;

    // PIN display (viewer, from host PeerChallenge)
    std::string viewerPendingPin_;
};

} // namespace peariscope
