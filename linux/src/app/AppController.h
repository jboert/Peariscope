#pragma once

#include <QObject>
#include <QString>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QTimer>
#include <QClipboard>
#include <QGuiApplication>
#include <QPainter>
#include <QPixmap>
#include <QtQml/qqmlregistration.h>

#include <memory>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <cstdint>
#include <functional>
#include <filesystem>

#include "capture/PipewireCapture.h"
#include "video/FfmpegEncoder.h"
#include "video/FfmpegDecoder.h"
#include "video/GlRenderer.h"
#include "input/X11InputCapture.h"
#include "input/X11InputInjector.h"
#include "networking/IpcBridge.h"
#include "app/AvahiAdvertiser.h"
#include "auth/KeyManager.h"
#include "audio/PwAudioCapture.h"
#include "audio/FfmpegAudioEncoder.h"
#include "audio/FfmpegAudioDecoder.h"
#include "audio/PwAudioPlayer.h"
#include "app/RecentConnectionsModel.h"
#include "app/SleepWakeMonitor.h"
#include "app/NetworkMonitor.h"
#include "app/NativeUpdater.h"

namespace peariscope {

/// Stream data channel identifiers matching the Pear protocol.
enum class StreamCh : uint8_t {
    Video   = 0,
    Input   = 1,
    Control = 2,
    Audio   = 3,
};

/// Settings persisted to disk.
struct AppSettings {
    bool runOnStartup       = false;
    bool shareOnStartup     = false;
    bool clipboardSync      = false;
    bool newCodeEachSession = false;
    bool shareAudio         = true;
    bool pinProtection      = true;
    QString pinCode         = "000000";
    int  maxPeers           = 5;
    int  accentColor        = 0;

    static AppSettings Load(const std::filesystem::path& dir);
    void Save(const std::filesystem::path& dir) const;
};

/// Main application controller — bridges backend logic to QML.
class AppController : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // App state
    Q_PROPERTY(int appMode READ appMode NOTIFY appModeChanged)
    Q_PROPERTY(int currentPage READ currentPage WRITE setCurrentPage NOTIFY currentPageChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)
    Q_PROPERTY(QString connectStatus READ connectStatus NOTIFY connectStatusChanged)

    // Hosting state
    Q_PROPERTY(QString connectionCode READ connectionCode NOTIFY connectionCodeChanged)
    Q_PROPERTY(QString qrMatrix READ qrMatrix NOTIFY qrMatrixChanged)
    Q_PROPERTY(int qrMatrixSize READ qrMatrixSize NOTIFY qrMatrixChanged)
    Q_PROPERTY(int peerCount READ peerCount NOTIFY peerCountChanged)
    Q_PROPERTY(double currentFps READ currentFps NOTIFY statsChanged)
    Q_PROPERTY(int currentBitrate READ currentBitrate NOTIFY statsChanged)
    Q_PROPERTY(bool isCodeRevealed READ isCodeRevealed NOTIFY codeRevealChanged)
    Q_PROPERTY(int captureWidth READ captureWidth NOTIFY statsChanged)
    Q_PROPERTY(int captureHeight READ captureHeight NOTIFY statsChanged)

    // Pending peer (PIN verification)
    Q_PROPERTY(QString pendingPeerKey READ pendingPeerKey NOTIFY pendingPeerChanged)
    Q_PROPERTY(QString pendingPeerPin READ pendingPeerPin NOTIFY pendingPeerChanged)
    Q_PROPERTY(bool hasPendingPeer READ hasPendingPeer NOTIFY pendingPeerChanged)

    // Viewer state
    Q_PROPERTY(int viewerFps READ viewerFps NOTIFY viewerStatsChanged)
    Q_PROPERTY(bool isReconnecting READ isReconnecting NOTIFY viewerStatsChanged)
    Q_PROPERTY(int reconnectAttempt READ reconnectAttempt NOTIFY viewerStatsChanged)
    Q_PROPERTY(int reconnectMaxAttempts READ reconnectMaxAttempts CONSTANT)
    Q_PROPERTY(bool connectionLost READ connectionLost NOTIFY viewerStatsChanged)
    Q_PROPERTY(QString lastConnectCode READ lastConnectCode NOTIFY lastConnectCodeChanged)
    Q_PROPERTY(bool viewerAwaitingPin READ viewerAwaitingPin NOTIFY viewerPinChanged)

    // Settings
    Q_PROPERTY(bool settingRunOnStartup READ settingRunOnStartup WRITE setSettingRunOnStartup NOTIFY settingsChanged)
    Q_PROPERTY(bool settingShareOnStartup READ settingShareOnStartup WRITE setSettingShareOnStartup NOTIFY settingsChanged)
    Q_PROPERTY(bool settingClipboardSync READ settingClipboardSync WRITE setSettingClipboardSync NOTIFY settingsChanged)
    Q_PROPERTY(bool settingNewCodeEachSession READ settingNewCodeEachSession WRITE setSettingNewCodeEachSession NOTIFY settingsChanged)
    Q_PROPERTY(bool settingShareAudio READ settingShareAudio WRITE setSettingShareAudio NOTIFY settingsChanged)
    Q_PROPERTY(bool settingPinProtection READ settingPinProtection WRITE setSettingPinProtection NOTIFY settingsChanged)
    Q_PROPERTY(QString settingPinCode READ settingPinCode WRITE setSettingPinCode NOTIFY settingsChanged)
    Q_PROPERTY(int settingMaxPeers READ settingMaxPeers WRITE setSettingMaxPeers NOTIFY settingsChanged)
    Q_PROPERTY(int settingAccentColor READ settingAccentColor WRITE setSettingAccentColor NOTIFY settingsChanged)

    // Recent connections model
    Q_PROPERTY(RecentConnectionsModel* recentConnections READ recentConnections CONSTANT)

    // Popup visibility
    Q_PROPERTY(bool popupVisible READ popupVisible WRITE setPopupVisible NOTIFY popupVisibleChanged)

    // Update notification
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY updateAvailableChanged)
    Q_PROPERTY(QString updateVersion READ updateVersion NOTIFY updateAvailableChanged)
    Q_PROPERTY(QString updateComponent READ updateComponent NOTIFY updateAvailableChanged)

public:
    explicit AppController(QObject* parent = nullptr);
    ~AppController() override;

    bool initialize();
    pid_t workletPid() const;

    // --- Property getters ---
    int appMode() const { return static_cast<int>(mode_); }
    int currentPage() const { return static_cast<int>(currentPage_); }
    QString statusText() const { return QString::fromStdString(statusText_); }
    QString connectStatus() const { return QString::fromStdString(connectStatus_); }

    QString connectionCode() const { return QString::fromStdString(connectionCode_); }
    QString qrMatrix() const { return QString::fromStdString(qrMatrix_); }
    int qrMatrixSize() const { return qrMatrixSize_; }
    int peerCount() const;
    double currentFps() const { return currentFps_; }
    int currentBitrate() const { return static_cast<int>(currentBitrate_); }
    bool isCodeRevealed() const { return codeRevealed_; }
    int captureWidth() const { return capture_ ? static_cast<int>(capture_->GetWidth()) : 0; }
    int captureHeight() const { return capture_ ? static_cast<int>(capture_->GetHeight()) : 0; }

    QString pendingPeerKey() const { return QString::fromStdString(pendingPeerKeyHex_); }
    QString pendingPeerPin() const { return QString::fromStdString(pendingPeerPin_); }
    bool hasPendingPeer() const { return !pendingPeerKeyHex_.empty() && !pendingPeerPin_.empty(); }

    int viewerFps() const { return static_cast<int>(viewerFps_); }
    bool isReconnecting() const { return isReconnecting_; }
    int reconnectAttempt() const { return reconnectAttempts_; }
    int reconnectMaxAttempts() const { return kMaxReconnectAttempts; }
    bool connectionLost() const { return connectionLost_; }
    QString lastConnectCode() const { return QString::fromStdString(lastConnectCode_); }
    bool viewerAwaitingPin() const { return viewerAwaitingPin_; }

    bool settingRunOnStartup() const { return settings_.runOnStartup; }
    bool settingShareOnStartup() const { return settings_.shareOnStartup; }
    bool settingClipboardSync() const { return settings_.clipboardSync; }
    bool settingNewCodeEachSession() const { return settings_.newCodeEachSession; }
    bool settingShareAudio() const { return settings_.shareAudio; }
    bool settingPinProtection() const { return settings_.pinProtection; }
    QString settingPinCode() const { return settings_.pinCode; }
    int settingMaxPeers() const { return settings_.maxPeers; }
    int settingAccentColor() const { return settings_.accentColor; }

    RecentConnectionsModel* recentConnections() { return &recentModel_; }

    bool popupVisible() const { return popupVisible_; }
    void setPopupVisible(bool v);

    bool updateAvailable() const { return updateAvailable_; }
    QString updateVersion() const { return QString::fromStdString(updateVersion_); }
    QString updateComponent() const { return QString::fromStdString(updateComponent_); }

    // --- Property setters ---
    void setCurrentPage(int page);
    void setSettingRunOnStartup(bool v);
    void setSettingShareOnStartup(bool v);
    void setSettingClipboardSync(bool v);
    void setSettingNewCodeEachSession(bool v);
    void setSettingShareAudio(bool v);
    void setSettingPinProtection(bool v);
    void setSettingPinCode(const QString& v);
    void setSettingMaxPeers(int v);
    void setSettingAccentColor(int v);

public slots:
    // --- Actions invokable from QML ---
    void startHosting();
    void stopHosting();
    void connectToHost(const QString& code);
    void disconnect();
    void toggleCodeReveal();
    void generateNewCode();
    void copyConnectionCode();
    void approvePeer();
    void rejectPeer();
    void submitViewerPin(const QString& pin);
    void deleteRecentConnection(int index);
    void renameRecentConnection(int index, const QString& name);
    void togglePinRecentConnection(int index);
    void quit();
    void togglePopup();
    void restartNetworking();
    void applyUpdate();
    void retryConnection();

signals:
    void appModeChanged();
    void currentPageChanged();
    void statusTextChanged();
    void connectStatusChanged();
    void connectionCodeChanged();
    void qrMatrixChanged();
    void peerCountChanged();
    void peerWantsApproval();
    void statsChanged();
    void codeRevealChanged();
    void pendingPeerChanged();
    void viewerStatsChanged();
    void lastConnectCodeChanged();
    void viewerPinChanged();
    void settingsChanged();
    void popupVisibleChanged();
    void updateAvailableChanged();

    // Signals for viewer window management (handled by main.cpp)
    void enterViewerMode();
    void exitViewerMode();

private:
    // --- Mode enums (matching original) ---
    enum class Mode { Idle, Hosting, Viewing, Settings };
    enum class Page { Host, Connect, Settings };

    // --- IPC callbacks ---
    void setupIpcCallbacks();
    void onHostingStarted(const std::string& publicKeyHex,
                          const std::string& connectionCode,
                          const std::string& qrMatrix, int qrSize);
    void onHostingStopped();
    void onPeerConnected(const std::string& peerKey, uint32_t streamId);
    void onPeerDisconnected(const std::string& peerKey);
    void onStreamData(uint32_t streamId, uint8_t channel,
                      const uint8_t* data, size_t size);
    void onConnectionFailed(const std::string& code, const std::string& reason,
                            const std::string& errorType = "");

    // --- Host pipeline ---
    void startCapture();
    void stopCapture();
    void startAudioCapture();
    void captureThreadFunc();
    void onEncodedFrame(const uint8_t* data, size_t size, bool isKeyframe);
    void forceKeyframe();
    void sendCursorPosition();
    void sendCodecNegotiation(uint32_t streamId);
    void sendDisplayList(uint32_t streamId);
    void sendFrameTimestamp();
    void sendControlData(const std::vector<uint8_t>& data, uint32_t streamId);
    void sendControlDataToAll(const std::vector<uint8_t>& data);

    // --- PIN verification ---
    void sendPinChallenge(const std::string& peerKeyHex, uint32_t streamId);
    void respondToPeer(bool accepted);
    void respondToPeerByKey(const std::string& peerKey, uint32_t streamId, bool accepted);

    // --- Viewer pipeline ---
    void initViewerPipeline();
    void onVideoReceived(uint32_t streamId, const uint8_t* data, size_t size);
    void onViewerControlReceived(uint32_t streamId, const uint8_t* data, size_t size);
    void onLocalInput(const X11InputCapture::InputEvent& event);
    void sendQualityReport();
    void sendRequestIdr();
    void attemptReconnect();

    // --- Viewer window (X11 + OpenGL) ---
    void enterViewerWindowMode();
    void exitViewerWindowMode();
    void viewerEventLoop();

    void* viewerDisplay_ = nullptr;       // Display*
    unsigned long viewerWindow_ = 0;      // Window
    bool isViewerWindow_ = false;
    std::thread viewerEventThread_;
    std::atomic<bool> viewerEventRunning_{false};

    // --- Protobuf ---
    static std::vector<uint8_t> serializeInputEvent(const X11InputCapture::InputEvent& event);
    void deserializeAndInjectInput(const uint8_t* data, size_t size);

    // --- Settings persistence ---
    void applySettings();
    void saveSettings();
    std::filesystem::path settingsDir();

    // --- Recent connections ---
    void loadRecentConnections();
    void saveRecentConnectionsFile();
    void saveRecentConnection(const std::string& code);
    void probeRecentConnectionStatus();
    std::string recentConnectionsPath();

    // --- Persistent code ---
    std::string savedCodePath();
    std::string loadSavedCode();
    void saveCode(const std::string& code);

    // --- Display management ---
    void refreshDisplayList();

    // --- Clipboard sync ---
    void checkClipboardChanged();
    void sendClipboardToAll();
    std::string readClipboardText();
    std::vector<uint8_t> readClipboardImage();
    void applyRemoteClipboard(const uint8_t* data, size_t size);

    // --- Logging ---
    static void nativeLog(const std::string& msg);

    // --- Emit helpers (thread-safe, posts to Qt event loop) ---
    void emitUiUpdate();

    // ================================================================
    // State
    // ================================================================
    Mode mode_ = Mode::Idle;
    Page currentPage_ = Page::Host;
    bool codeRevealed_ = false;
    bool popupVisible_ = true;

    // System tray
    std::unique_ptr<QSystemTrayIcon> trayIcon_;
    std::unique_ptr<QMenu> trayMenu_;
    void setupTrayIcon();

    // Timers (Qt timers replace platform-specific timers)
    QTimer fpsTimer_;
    QTimer cursorTimer_;
    QTimer qualityTimer_;
    QTimer clipboardTimer_;
    QTimer reconnectTimer_;
    QTimer watchdogTimer_;

    // Settings
    AppSettings settings_;

    // Components
    std::unique_ptr<GlRenderer>        renderer_;
    std::unique_ptr<PipewireCapture>   capture_;
    std::unique_ptr<FfmpegEncoder>     encoder_;
    std::unique_ptr<FfmpegDecoder>     decoder_;
    std::unique_ptr<X11InputCapture>   inputCapture_;
    std::unique_ptr<X11InputInjector>  inputInjector_;
    std::unique_ptr<IpcBridge>         ipcBridge_;
    std::unique_ptr<KeyManager>        keyManager_;
    std::unique_ptr<SleepWakeMonitor>  sleepWakeMonitor_;
    std::unique_ptr<NetworkMonitor>    networkMonitor_;
    std::unique_ptr<NativeUpdater>     nativeUpdater_;
    std::unique_ptr<AvahiAdvertiser>   avahiAdvertiser_;

    // Audio
    std::unique_ptr<PwAudioCapture>      audioCapture_;
    std::unique_ptr<FfmpegAudioEncoder>  audioEncoder_;
    std::unique_ptr<FfmpegAudioDecoder>  audioDecoder_;
    std::unique_ptr<PwAudioPlayer>       audioPlayer_;

    // Host state
    std::string connectionCode_;
    std::string publicKeyHex_;
    std::string qrMatrix_;
    int         qrMatrixSize_ = 0;
    std::atomic<uint32_t> frameCount_{0};
    std::atomic<uint32_t> framesInSecond_{0};
    double      currentFps_     = 0.0;
    bool        isCaptureRunning_ = false;

    // Capture thread
    std::thread captureThread_;
    std::atomic<bool> captureThreadRunning_{false};

    // Cursor tracking
    float lastCursorX_ = -1.0f;
    float lastCursorY_ = -1.0f;

    // Input rate limiting
    uint32_t inputEventsThisSecond_ = 0;
    static constexpr uint32_t kMaxInputEventsPerSecond = 500;

    // PIN verification (host)
    std::string pendingPeerPin_;
    std::string pendingPeerKeyHex_;
    std::unordered_set<std::string> pendingPeerIds_;
    uint32_t pendingPeerTimeout_ = 0;
    bool requirePin_ = false;
    std::string pinCode_;

    // Display management
    std::vector<NativeDisplayInfo> availableDisplays_;
    uint32_t selectedDisplayIndex_ = 0;

    // Peer tracking
    struct PeerState {
        std::string peerKeyHex;
        std::string name;
        uint32_t    streamId = 0;
    };
    std::mutex                          peerMutex_;
    std::vector<PeerState>              connectedPeers_;
    std::unordered_set<std::string>     peerKeySet_;
    std::unordered_set<std::string>     approvedPeerKeys_;

    // Connection state
    std::string statusText_ = "Ready";
    std::string connectStatus_;
    std::string lastError_;

    // Viewer state
    std::string lastConnectCode_;
    bool isReconnecting_ = false;
    bool connectionLost_ = false;
    int  reconnectAttempts_ = 0;
    static constexpr int kMaxReconnectAttempts = 5;
    bool wasHostingBeforeViewing_ = false;
    bool intentionalDisconnect_ = false;

    // Viewer stats
    uint32_t viewerFps_ = 0;
    uint32_t viewerFrameCount_ = 0;
    uint32_t noFrameSeconds_ = 0;

    // Decoder rate limiting
    std::atomic<uint32_t> pendingDecodes_{0};
    static constexpr uint32_t kMaxPendingDecodes = 3;
    uint64_t lastDecodeTickMs_ = 0;
    static constexpr uint64_t kMinDecodeIntervalMs = 8;
    uint32_t lastDecoderWidth_ = 0;
    uint32_t lastDecoderHeight_ = 0;

    // Adaptive quality
    uint32_t currentBitrate_ = 20000000;
    static constexpr uint32_t kMinBitrate = 2000000;
    static constexpr uint32_t kMaxBitrate = 12000000;
    uint32_t lowFpsReports_ = 0;
    uint32_t goodFpsReports_ = 0;

    // Remote cursor
    float remoteCursorX_ = 0.5f;
    float remoteCursorY_ = 0.5f;

    // PIN entry (viewer)
    std::string viewerPendingPin_;
    uint32_t viewerPinStreamId_ = 0;
    bool viewerAwaitingPin_ = false;

    // Clipboard sync
    bool  suppressNextClipboard_ = false;
    static constexpr size_t kMaxClipboardText  = 1 * 1024 * 1024;
    static constexpr size_t kMaxClipboardImage = 10 * 1024 * 1024;

    // Update state
    bool updateAvailable_ = false;
    std::string updateVersion_;
    std::string updateComponent_;

    // Saved code
    std::string savedCode_;

    // Recent connections
    RecentConnectionsModel recentModel_;
    struct RecentEntry {
        std::string code;
        std::string name;
        std::string timestamp;
        bool pinned = false;
        int  onlineStatus = 0;
    };
    std::vector<RecentEntry> recentEntries_;
    static constexpr int kMaxRecentConnections = 10;
};

} // namespace peariscope
