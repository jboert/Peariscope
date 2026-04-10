#include "AppController.h"
#include "CrashLog.h"
#include "QrCode.h"
#include "messages.pb.h"
extern "C" {
#include <libavutil/frame.h>
}
#include <QClipboard>
#include <QGuiApplication>
#include <QIcon>
#include <QPixmap>
#include <QImage>
#include <QBuffer>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <fstream>
#include <filesystem>
#include <algorithm>
#include <cstdlib>
#include <climits>
#include <unistd.h>
#include <time.h>

// Global worklet PID for async-signal-safe crash cleanup (defined in main.cpp)
extern volatile pid_t g_workletPid;

#include <X11/Xlib.h>
#include <X11/Xatom.h>

namespace peariscope {

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

static std::filesystem::path ExeDir() {
    char exePath[PATH_MAX]{};
    ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
    if (len > 0) exePath[len] = '\0';
    return std::filesystem::path(exePath).parent_path();
}

static uint64_t MonotonicMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

void AppController::nativeLog(const std::string& msg) {
    static std::ofstream logFile;
    if (!logFile.is_open()) {
        auto logPath = ExeDir() / "peariscope.log";
        logFile.open(logPath, std::ios::app);
    }
    if (logFile.is_open()) {
        auto now = std::chrono::system_clock::now();
        auto t = std::chrono::system_clock::to_time_t(now);
        char timeBuf[32];
        std::strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", std::localtime(&t));
        logFile << "[" << timeBuf << "] [native] " << msg << "\n";
        logFile.flush();
    }
}

// -----------------------------------------------------------------------
// Settings persistence
// -----------------------------------------------------------------------

AppSettings AppSettings::Load(const std::filesystem::path& dir) {
    AppSettings s;
    auto path = dir / "peariscope-settings.txt";
    std::ifstream f(path);
    if (!f.is_open()) return s;
    std::string line;
    while (std::getline(f, line)) {
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq);
        std::string val = line.substr(eq + 1);
        if (key == "runOnStartup")       s.runOnStartup       = (val == "1");
        else if (key == "shareOnStartup")     s.shareOnStartup     = (val == "1");
        else if (key == "clipboardSync")      s.clipboardSync      = (val == "1");
        else if (key == "newCodeEachSession") s.newCodeEachSession = (val == "1");
        else if (key == "shareAudio")         s.shareAudio         = (val == "1");
        else if (key == "pinProtection")      s.pinProtection      = (val == "1");
        else if (key == "pinCode")            s.pinCode            = QString::fromStdString(val);
        else if (key == "maxPeers")           s.maxPeers           = std::stoi(val);
        else if (key == "accentColor")        s.accentColor        = std::stoi(val);
    }
    if (s.maxPeers < 1) s.maxPeers = 1;
    if (s.maxPeers > 20) s.maxPeers = 20;
    if (s.accentColor < 0 || s.accentColor > 7) s.accentColor = 0;
    return s;
}

void AppSettings::Save(const std::filesystem::path& dir) const {
    auto path = dir / "peariscope-settings.txt";
    std::ofstream f(path);
    if (!f.is_open()) return;
    f << "runOnStartup="       << (runOnStartup ? "1" : "0")       << "\n";
    f << "shareOnStartup="     << (shareOnStartup ? "1" : "0")     << "\n";
    f << "clipboardSync="      << (clipboardSync ? "1" : "0")      << "\n";
    f << "newCodeEachSession=" << (newCodeEachSession ? "1" : "0") << "\n";
    f << "shareAudio="         << (shareAudio ? "1" : "0")         << "\n";
    f << "pinProtection="      << (pinProtection ? "1" : "0")      << "\n";
    f << "pinCode="            << pinCode.toStdString()             << "\n";
    f << "maxPeers="           << maxPeers                          << "\n";
    f << "accentColor="        << accentColor                       << "\n";
}

// -----------------------------------------------------------------------
// Constructor / Destructor
// -----------------------------------------------------------------------

AppController::AppController(QObject* parent) : QObject(parent) {
    // Setup Qt timers
    connect(&fpsTimer_, &QTimer::timeout, this, [this]() {
        if (mode_ == Mode::Hosting) {
            currentFps_ = framesInSecond_;
            framesInSecond_ = 0;
            inputEventsThisSecond_ = 0;

            // Clear stale peer-connecting card
            if (!pendingPeerKeyHex_.empty()) {
                std::lock_guard<std::mutex> lock(peerMutex_);
                bool stillConnected = false;
                for (const auto& p : connectedPeers_) {
                    if (p.peerKeyHex == pendingPeerKeyHex_) { stillConnected = true; break; }
                }
                if (!stillConnected) {
                    pendingPeerIds_.erase(pendingPeerKeyHex_);
                    pendingPeerKeyHex_.clear();
                    pendingPeerPin_.clear();
                    statusText_ = "Sharing";
                    emit pendingPeerChanged();
                }
            }

            // Auto-approve pending peers after 60s
            if (!pendingPeerIds_.empty()) {
                pendingPeerTimeout_++;
                if (pendingPeerTimeout_ >= 60) {
                    std::vector<std::pair<std::string, uint32_t>> toApprove;
                    {
                        std::lock_guard<std::mutex> lock(peerMutex_);
                        for (const auto& p : connectedPeers_) {
                            if (pendingPeerIds_.count(p.peerKeyHex)) {
                                toApprove.push_back({p.peerKeyHex, p.streamId});
                            }
                        }
                    }
                    for (auto& [key, sid] : toApprove) {
                        respondToPeerByKey(key, sid, true);
                    }
                    pendingPeerTimeout_ = 0;
                }
            } else {
                pendingPeerTimeout_ = 0;
            }

            size_t peers = 0;
            { std::lock_guard<std::mutex> lock(peerMutex_); peers = connectedPeers_.size(); }
            CrashLog::Heartbeat(currentFps_, peers);

            emit statsChanged();
        } else if (mode_ == Mode::Viewing) {
            viewerFps_ = viewerFrameCount_;
            viewerFrameCount_ = 0;

            // Update viewer window title
            if (viewerWindow_ && viewerDisplay_) {
                std::string title = "Peariscope";
                if (viewerAwaitingPin_) title += " - PIN Required";
                else if (viewerFps_ > 0) title += " - " + std::to_string(viewerFps_) + " fps";
                else if (isReconnecting_) title += " - Reconnecting...";
                else title += " - Waiting for video...";
                XStoreName(static_cast<Display*>(viewerDisplay_), viewerWindow_, title.c_str());
                XFlush(static_cast<Display*>(viewerDisplay_));
            }

            // Stale connection detection
            if (viewerFps_ == 0 && !isReconnecting_) {
                noFrameSeconds_++;
                if (noFrameSeconds_ >= 2 && noFrameSeconds_ <= 10) sendRequestIdr();
                if (noFrameSeconds_ >= 15) attemptReconnect();
            } else {
                noFrameSeconds_ = 0;
            }

            size_t peers = 0;
            { std::lock_guard<std::mutex> lock(peerMutex_); peers = connectedPeers_.size(); }
            CrashLog::Heartbeat(viewerFps_, peers);

            emit viewerStatsChanged();
        }
    });

    connect(&cursorTimer_, &QTimer::timeout, this, [this]() {
        if (mode_ == Mode::Hosting) sendCursorPosition();
    });

    connect(&qualityTimer_, &QTimer::timeout, this, [this]() {
        if (mode_ == Mode::Viewing) sendQualityReport();
    });

    connect(&clipboardTimer_, &QTimer::timeout, this, [this]() {
        checkClipboardChanged();
    });

    // Watchdog: detect worklet death and auto-restart
    connect(&watchdogTimer_, &QTimer::timeout, this, [this]() {
        if (!ipcBridge_ || mode_ == Mode::Idle) return;
        if (!ipcBridge_->IsAlive()) {
            nativeLog("Watchdog: worklet died, restarting networking");
            restartNetworking();
            g_workletPid = workletPid();
        }
    });
    watchdogTimer_.start(10000); // every 10s
}

pid_t AppController::workletPid() const {
    return ipcBridge_ ? ipcBridge_->ChildPid() : -1;
}

AppController::~AppController() {
    stopHosting();
    disconnect();
    if (ipcBridge_) ipcBridge_->Stop();
}

// -----------------------------------------------------------------------
// Initialize
// -----------------------------------------------------------------------

bool AppController::initialize() {
    CrashLog::CheckPreviousCrash();
    CrashLog::Init();

    keyManager_ = std::make_unique<KeyManager>();
    ipcBridge_ = std::make_unique<IpcBridge>();
    nativeUpdater_ = std::make_unique<NativeUpdater>(this);
    setupIpcCallbacks();

    // Setup sleep/wake monitoring via D-Bus
    sleepWakeMonitor_ = std::make_unique<SleepWakeMonitor>(this);
    sleepWakeMonitor_->onSleep = [this]() {
        nativeLog("System sleeping, suspending Hyperswarm");
        if (ipcBridge_) ipcBridge_->Suspend();
    };
    sleepWakeMonitor_->onWake = [this]() {
        nativeLog("System waking, resuming Hyperswarm");
        if (ipcBridge_) ipcBridge_->Resume();
        // Belt-and-suspenders: also send explicit REANNOUNCE after a delay
        // to ensure DHT topic is refreshed after resume completes
        if (mode_ == Mode::Hosting) {
            QTimer::singleShot(2000, this, [this]() {
                if (ipcBridge_ && mode_ == Mode::Hosting) {
                    nativeLog("Post-wake REANNOUNCE");
                    ipcBridge_->Reannounce();
                }
            });
        }
    };

    // Setup network change monitoring via NetworkManager D-Bus
    networkMonitor_ = std::make_unique<NetworkMonitor>(this);
    networkMonitor_->onNetworkUp = [this]() {
        if (ipcBridge_ && mode_ == Mode::Hosting) {
            nativeLog("Network restored while hosting, sending REANNOUNCE");
            ipcBridge_->Reannounce();
        }
    };

    // Load settings
    settings_ = AppSettings::Load(settingsDir());
    applySettings();

    // Load persistent code and recent connections
    savedCode_ = loadSavedCode();
    loadRecentConnections();

    if (settings_.newCodeEachSession) {
        savedCode_.clear();
        std::filesystem::remove(savedCodePath());
    }

    // Setup system tray
    setupTrayIcon();

    // Start networking
    if (!ipcBridge_->Start()) {
        statusText_ = "Failed to start networking";
        emit statusTextChanged();
    } else {
        statusText_ = "Networking ready";
        ipcBridge_->SendCachedDhtNodes();
        if (settings_.shareOnStartup) {
            startHosting();
        }
        emit statusTextChanged();
    }

    return true;
}

// -----------------------------------------------------------------------
// System tray
// -----------------------------------------------------------------------

void AppController::setupTrayIcon() {
    trayIcon_ = std::make_unique<QSystemTrayIcon>(this);
    trayMenu_ = std::make_unique<QMenu>();

    // Load icon from assets
    auto iconPath = ExeDir() / "assets" / "app-logo@3x.png";
    if (!std::filesystem::exists(iconPath)) {
        auto srcDir = ExeDir().parent_path().parent_path().parent_path();
        iconPath = srcDir / "assets" / "app-logo@3x.png";
    }

    if (std::filesystem::exists(iconPath)) {
        QIcon icon(QString::fromStdString(iconPath.string()));
        trayIcon_->setIcon(icon);
    } else {
        // Fallback: create a simple green circle icon
        QPixmap pix(32, 32);
        pix.fill(Qt::transparent);
        QPainter painter(&pix);
        painter.setBrush(QColor(156, 226, 45));
        painter.setPen(Qt::NoPen);
        painter.drawEllipse(2, 2, 28, 28);
        painter.end();
        trayIcon_->setIcon(QIcon(pix));
    }

    trayIcon_->setToolTip("Peariscope");

    auto* showAction = trayMenu_->addAction("Show");
    connect(showAction, &QAction::triggered, this, [this]() {
        setPopupVisible(true);
    });
    auto* quitAction = trayMenu_->addAction("Quit");
    connect(quitAction, &QAction::triggered, this, &AppController::quit);

    trayIcon_->setContextMenu(trayMenu_.get());

    connect(trayIcon_.get(), &QSystemTrayIcon::activated, this,
            [this](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger) {
            togglePopup();
        }
    });

    trayIcon_->show();
}

// -----------------------------------------------------------------------
// Thread-safe UI update
// -----------------------------------------------------------------------

void AppController::emitUiUpdate() {
    // Post to Qt event loop from any thread
    QMetaObject::invokeMethod(this, [this]() {
        emit appModeChanged();
        emit statusTextChanged();
        emit peerCountChanged();
        emit statsChanged();
        emit pendingPeerChanged();
    }, Qt::QueuedConnection);
}

// -----------------------------------------------------------------------
// Property setters
// -----------------------------------------------------------------------

void AppController::setCurrentPage(int page) {
    auto p = static_cast<Page>(page);
    if (currentPage_ == p) return;
    currentPage_ = p;
    if (p == Page::Connect) probeRecentConnectionStatus();
    emit currentPageChanged();
}

void AppController::setPopupVisible(bool v) {
    if (popupVisible_ == v) return;
    popupVisible_ = v;
    emit popupVisibleChanged();
}

void AppController::setSettingRunOnStartup(bool v) {
    settings_.runOnStartup = v; saveSettings(); applySettings(); emit settingsChanged();
}
void AppController::setSettingShareOnStartup(bool v) {
    settings_.shareOnStartup = v; saveSettings(); emit settingsChanged();
}
void AppController::setSettingClipboardSync(bool v) {
    settings_.clipboardSync = v; saveSettings(); applySettings(); emit settingsChanged();
}
void AppController::setSettingNewCodeEachSession(bool v) {
    settings_.newCodeEachSession = v; saveSettings(); emit settingsChanged();
}
void AppController::setSettingShareAudio(bool v) {
    settings_.shareAudio = v; saveSettings(); applySettings(); emit settingsChanged();
}
void AppController::setSettingPinProtection(bool v) {
    settings_.pinProtection = v; saveSettings(); applySettings(); emit settingsChanged();
}
void AppController::setSettingPinCode(const QString& v) {
    settings_.pinCode = v;
    if (keyManager_) keyManager_->SavePin(v.toStdString());
    saveSettings(); applySettings(); emit settingsChanged();
}
void AppController::setSettingMaxPeers(int v) {
    settings_.maxPeers = std::clamp(v, 1, 20); saveSettings(); emit settingsChanged();
}
void AppController::setSettingAccentColor(int v) {
    settings_.accentColor = std::clamp(v, 0, 7); saveSettings(); emit settingsChanged();
}

void AppController::saveSettings() {
    settings_.Save(settingsDir());
}

int AppController::peerCount() const {
    std::lock_guard<std::mutex> lock(const_cast<std::mutex&>(peerMutex_));
    int total = static_cast<int>(connectedPeers_.size());
    int pending = static_cast<int>(pendingPeerIds_.size());
    return total - pending;
}

// -----------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------

void AppController::toggleCodeReveal() {
    codeRevealed_ = !codeRevealed_;
    emit codeRevealChanged();
}

void AppController::generateNewCode() {
    savedCode_.clear();
    std::filesystem::remove(savedCodePath());
    stopHosting();
    startHosting();
}

void AppController::copyConnectionCode() {
    if (!connectionCode_.empty()) {
        auto* clipboard = QGuiApplication::clipboard();
        clipboard->setText(QString::fromStdString(connectionCode_));
    }
}

void AppController::approvePeer() {
    if (!pendingPeerKeyHex_.empty()) {
        respondToPeer(true);
    }
}

void AppController::rejectPeer() {
    if (!pendingPeerKeyHex_.empty()) {
        respondToPeer(false);
    }
}

void AppController::togglePopup() {
    setPopupVisible(!popupVisible_);
}

void AppController::restartNetworking() {
    nativeLog("Restarting networking subsystem");
    if (!ipcBridge_) return;

    // Remember current state to restore after restart
    bool wasHosting = (mode_ == Mode::Hosting);
    std::string savedCode = connectionCode_;

    ipcBridge_->Stop();
    if (!ipcBridge_->Start()) {
        statusText_ = "Failed to restart networking";
        g_workletPid = -1;
        emit statusTextChanged();
        return;
    }

    g_workletPid = workletPid();
    statusText_ = "Networking restarted";
    ipcBridge_->SendCachedDhtNodes();
    updateAvailable_ = false;
    updateVersion_.clear();
    updateComponent_.clear();
    emit updateAvailableChanged();
    emit statusTextChanged();

    // Restore hosting state
    if (wasHosting && !savedCode.empty()) {
        nativeLog("Restoring hosting after restart");
        ipcBridge_->StartHosting(savedCode);
    }
}

void AppController::applyUpdate() {
    if (nativeUpdater_ && nativeUpdater_->HasPendingUpdate()) {
        if (nativeUpdater_->PendingComponent() == "js") {
            restartNetworking();
        } else {
            nativeUpdater_->ApplyUpdate();
        }
    }
}

void AppController::quit() {
    stopHosting();
    disconnect();
    if (ipcBridge_) ipcBridge_->Stop();
    if (trayIcon_) trayIcon_->hide();
    QGuiApplication::quit();
}

// -----------------------------------------------------------------------
// IPC callbacks
// -----------------------------------------------------------------------

void AppController::setupIpcCallbacks() {
    ipcBridge_->onHostingStarted = [this](const HostingStartedEvent& e) {
        onHostingStarted(e.publicKeyHex, e.connectionCode, e.qrMatrix, e.qrSize);
    };
    ipcBridge_->onHostingStopped = [this]() { onHostingStopped(); };
    ipcBridge_->onPeerConnected = [this](const PeerConnectedEvent& e) {
        onPeerConnected(e.peerKeyHex, e.streamId);
    };
    ipcBridge_->onPeerDisconnected = [this](const PeerDisconnectedEvent& e) {
        onPeerDisconnected(e.peerKeyHex);
    };
    ipcBridge_->onStreamData = [this](const StreamDataEvent& e) {
        onStreamData(e.streamId, e.channel, e.data.data(), e.data.size());
    };
    ipcBridge_->onConnectionFailed = [this](const ConnectionFailedEvent& e) {
        onConnectionFailed(e.code, e.reason, e.errorType);
    };
    ipcBridge_->onConnectionState = [this](const ConnectionStateEvent& e) {
        nativeLog("Connection state: " + e.state + " - " + e.detail +
                  " (attempt " + std::to_string(e.attempt) + "/" + std::to_string(e.maxAttempts) + ")");
        if (mode_ == Mode::Viewing && !isReconnecting_) {
            connectStatus_ = e.detail;
            QMetaObject::invokeMethod(this, [this]() {
                emit connectStatusChanged();
            }, Qt::QueuedConnection);
        }
    };
    ipcBridge_->onConnectionEstablished = [this](const ConnectionEstablishedEvent& e) {
        nativeLog("Connection established: " + e.peerKeyHex.substr(0, 16));
    };
    ipcBridge_->onLog = [](const std::string& msg) {
        nativeLog(msg);
    };
    ipcBridge_->onError = [this](const std::string& msg) {
        lastError_ = msg;
        statusText_ = "Error: " + msg;
        emitUiUpdate();
    };
    ipcBridge_->onLookupResult = [this](const LookupResultEvent& e) {
        QMetaObject::invokeMethod(this, [this, code = e.code, online = e.online]() {
            recentModel_.updateOnlineStatus(QString::fromStdString(code), online ? 1 : -1);
        }, Qt::QueuedConnection);
    };
    ipcBridge_->onUpdateAvailable = [this](const UpdateAvailableEvent& e) {
        QMetaObject::invokeMethod(this, [this, ver = e.version, comp = e.component, path = e.downloadPath]() {
            updateAvailable_ = true;
            updateVersion_ = ver;
            updateComponent_ = comp;
            emit updateAvailableChanged();
            nativeLog("Update available: " + comp + " v" + ver);
            if (nativeUpdater_) {
                nativeUpdater_->OnUpdateAvailable(ver, path, comp);
            }
        }, Qt::QueuedConnection);
    };
}

void AppController::onHostingStarted(const std::string& publicKeyHex,
                                      const std::string& connectionCode,
                                      const std::string& qrMatrix, int qrSize) {
    publicKeyHex_ = publicKeyHex;
    connectionCode_ = connectionCode;
    statusText_ = "Hosting active";

    // Generate QR code from connection code (C++ side — worklet may not provide it)
    if (qrMatrix.empty() || qrSize == 0) {
        QrCode qr;
        // QR code uses uppercase connection code (matches iOS scanner)
        std::string upper = connectionCode;
        std::transform(upper.begin(), upper.end(), upper.begin(), ::toupper);
        if (qr.Generate(upper)) {
            qrMatrixSize_ = qr.GetSize();
            qrMatrix_.clear();
            for (int y = 0; y < qrMatrixSize_; y++)
                for (int x = 0; x < qrMatrixSize_; x++)
                    qrMatrix_ += qr.GetModule(x, y) ? '1' : '0';
        } else {
            qrMatrix_.clear();
            qrMatrixSize_ = 0;
        }
    } else {
        qrMatrix_ = qrMatrix;
        qrMatrixSize_ = qrSize;
    }

    if (savedCode_ != connectionCode) {
        savedCode_ = connectionCode;
        saveCode(connectionCode);
    }

    // Advertise via Avahi mDNS for local network discovery
    if (!avahiAdvertiser_) avahiAdvertiser_ = std::make_unique<AvahiAdvertiser>();
    char hostname[256] = {};
    gethostname(hostname, sizeof(hostname) - 1);
    avahiAdvertiser_->Start(connectionCode, hostname);

    QMetaObject::invokeMethod(this, [this]() {
        emit connectionCodeChanged();
        emit qrMatrixChanged();
        emit statusTextChanged();
    }, Qt::QueuedConnection);
}

void AppController::onHostingStopped() {
    if (avahiAdvertiser_) avahiAdvertiser_->Stop();
    mode_ = Mode::Idle;
    connectionCode_.clear();
    statusText_ = "Hosting stopped";
    emitUiUpdate();
}

void AppController::onPeerConnected(const std::string& peerKey, uint32_t streamId) {
    nativeLog("Peer connected: " + peerKey.substr(0, 16) + " sid=" + std::to_string(streamId));
    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        if (peerKeySet_.count(peerKey)) {
            // Dedup: same peer reconnected on surviving stream — update streamId
            nativeLog("Dedup: updating streamId for " + peerKey.substr(0, 16));
            for (auto& p : connectedPeers_) {
                if (p.peerKeyHex == peerKey) {
                    p.streamId = streamId;
                    break;
                }
            }
            // Re-send PIN challenge on the new stream if peer was pending
            if (mode_ == Mode::Hosting && pendingPeerIds_.count(peerKey)) {
                ipcBridge_->blockedStreamIds.insert(streamId);
                nativeLog("Dedup: re-sending PIN challenge on new stream");
                sendPinChallenge(peerKey, streamId);
            }
            return;
        }
        if (static_cast<int>(connectedPeers_.size()) >= settings_.maxPeers) {
            nativeLog("Max peers reached, rejecting");
            ipcBridge_->Disconnect(peerKey);
            return;
        }
        peerKeySet_.insert(peerKey);
        connectedPeers_.push_back({peerKey, "", streamId});
    }

    if (mode_ == Mode::Hosting) {
        if (requirePin_ && !pinCode_.empty() && !approvedPeerKeys_.count(peerKey)) {
            pendingPeerIds_.insert(peerKey);
            pendingPeerKeyHex_ = peerKey;
            pendingPeerPin_ = pinCode_;
            ipcBridge_->blockedStreamIds.insert(streamId);
            nativeLog("PIN challenge sent to " + peerKey.substr(0, 16));
            sendPinChallenge(peerKey, streamId);
            statusText_ = "Peer connecting — awaiting PIN verification";
            QMetaObject::invokeMethod(this, [this]() {
                emit pendingPeerChanged();
                emit statusTextChanged();
                emit peerCountChanged();
                setPopupVisible(true);
                emit peerWantsApproval();
            }, Qt::QueuedConnection);
        } else {
            // No PIN — start video + audio immediately
            QMetaObject::invokeMethod(this, [this, streamId]() {
                if (!isCaptureRunning_) startCapture();
                startAudioCapture();
                sendCodecNegotiation(streamId);
                sendDisplayList(streamId);
                forceKeyframe();
                // Extra keyframes
                QTimer::singleShot(200, this, [this]() { forceKeyframe(); });
                QTimer::singleShot(500, this, [this]() { forceKeyframe(); });
                statusText_ = "Peer connected";
                emit statusTextChanged();
                emit peerCountChanged();
            }, Qt::QueuedConnection);
        }
    } else if (mode_ == Mode::Viewing) {
        bool wasReconnecting = isReconnecting_;
        isReconnecting_ = false;
        connectionLost_ = false;
        reconnectAttempts_ = 0;
        noFrameSeconds_ = 0;
        connectStatus_.clear();
        statusText_ = "Connected to host";
        QMetaObject::invokeMethod(this, [this, wasReconnecting]() {
            initViewerPipeline();
            // Don't send codec negotiation immediately — wait for host to send
            // PIN challenge or codec negotiation first. Sending unsolicited data
            // can cause the host to reset the connection.
            if (wasReconnecting) {
                // Request IDR keyframe — decoder state is stale after reconnect
                QTimer::singleShot(500, this, [this]() { sendRequestIdr(); });
            }
            emit connectStatusChanged();
            emit statusTextChanged();
            emit viewerStatsChanged();
        }, Qt::QueuedConnection);
    }

    emitUiUpdate();
}

void AppController::onPeerDisconnected(const std::string& peerKey) {
    bool wasViewing = (mode_ == Mode::Viewing);
    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        // Grab streamId before erasing so we can unblock it
        for (const auto& p : connectedPeers_) {
            if (p.peerKeyHex == peerKey && p.streamId > 0) {
                ipcBridge_->blockedStreamIds.erase(p.streamId);
                break;
            }
        }
        peerKeySet_.erase(peerKey);
        connectedPeers_.erase(
            std::remove_if(connectedPeers_.begin(), connectedPeers_.end(),
                           [&](const PeerState& p) { return p.peerKeyHex == peerKey; }),
            connectedPeers_.end());
        if (pendingPeerIds_.count(peerKey)) {
            pendingPeerIds_.erase(peerKey);
            if (pendingPeerKeyHex_ == peerKey) {
                pendingPeerPin_.clear();
                pendingPeerKeyHex_.clear();
            }
        }
    }

    if (mode_ == Mode::Hosting) {
        bool shouldStop = false;
        {
            std::lock_guard<std::mutex> lock(peerMutex_);
            bool hasApprovedPeers = false;
            for (const auto& p : connectedPeers_) {
                if (!pendingPeerIds_.count(p.peerKeyHex)) { hasApprovedPeers = true; break; }
            }
            shouldStop = !hasApprovedPeers && isCaptureRunning_;
        }
        if (shouldStop) {
            // Stop capture on Qt thread to avoid blocking IPC read thread
            QMetaObject::invokeMethod(this, [this]() { stopCapture(); }, Qt::QueuedConnection);
        }
    }

    statusText_ = "Peer disconnected";
    emitUiUpdate();

    if (wasViewing && connectedPeers_.empty()) {
        if (intentionalDisconnect_) {
            QMetaObject::invokeMethod(this, [this]() { disconnect(); }, Qt::QueuedConnection);
        } else {
            // Unexpected disconnect — auto-reconnect
            nativeLog("Unexpected viewer disconnect, attempting reconnect");
            QMetaObject::invokeMethod(this, [this]() { attemptReconnect(); }, Qt::QueuedConnection);
        }
    }
}

void AppController::onStreamData(uint32_t streamId, uint8_t channel,
                                  const uint8_t* data, size_t size) {
    // Note: input (ch1) and audio (ch3) from unverified peers are now
    // blocked at the IpcBridge level via blockedStreamIds.

    switch (channel) {
    case 0: onVideoReceived(streamId, data, size); break;
    case 1:
        if (inputEventsThisSecond_ < kMaxInputEventsPerSecond) {
            inputEventsThisSecond_++;
            deserializeAndInjectInput(data, size);
        }
        break;
    case 2:
        if (mode_ == Mode::Hosting) {
            // Parse and handle host control messages
            peariscope::ControlMessage control;
            if (!control.ParseFromArray(data, static_cast<int>(size))) {
                nativeLog("ch2 protobuf parse FAILED: size=" + std::to_string(size) +
                          " hex=" + ([&]() {
                              std::string h;
                              for (size_t i = 0; i < std::min(size, (size_t)16); i++) {
                                  char buf[4]; snprintf(buf, sizeof(buf), "%02x", data[i]); h += buf;
                              }
                              return h;
                          })());
                return;
            }
            switch (control.msg_case()) {
            case peariscope::ControlMessage::kRequestIdr:
                forceKeyframe();
                QMetaObject::invokeMethod(this, [this]() {
                    QTimer::singleShot(200, this, [this]() { forceKeyframe(); });
                    QTimer::singleShot(500, this, [this]() { forceKeyframe(); });
                }, Qt::QueuedConnection);
                break;
            case peariscope::ControlMessage::kQualityReport: {
                auto& report = control.quality_report();
                uint32_t vfps = report.fps();
                float loss = report.packet_loss();
                constexpr uint32_t kTargetFps = 25;
                if (vfps < kTargetFps / 2 || loss > 0.1f) {
                    goodFpsReports_ = 0; lowFpsReports_++;
                    if (lowFpsReports_ >= 3 && currentBitrate_ > kMinBitrate) {
                        currentBitrate_ = std::max(kMinBitrate, currentBitrate_ / 2);
                        if (encoder_) encoder_->SetBitrate(currentBitrate_);
                        lowFpsReports_ = 0;
                    }
                } else if (vfps > kTargetFps * 9 / 10) {
                    lowFpsReports_ = 0; goodFpsReports_++;
                    if (goodFpsReports_ >= 3 && currentBitrate_ < kMaxBitrate) {
                        currentBitrate_ = std::min(kMaxBitrate, currentBitrate_ * 3 / 2);
                        if (encoder_) encoder_->SetBitrate(currentBitrate_);
                        goodFpsReports_ = 0;
                    }
                } else { lowFpsReports_ = 0; goodFpsReports_ = 0; }
                break;
            }
            case peariscope::ControlMessage::kClipboard:
                if (settings_.clipboardSync) applyRemoteClipboard(data, size);
                break;
            case peariscope::ControlMessage::kSwitchDisplay: {
                auto& sw = control.switch_display();
                uint32_t newIdx = sw.display_id();
                if (newIdx < availableDisplays_.size() && newIdx != selectedDisplayIndex_) {
                    selectedDisplayIndex_ = newIdx;
                    if (isCaptureRunning_) {
                        QMetaObject::invokeMethod(this, [this]() {
                            stopCapture(); startCapture();
                            std::lock_guard<std::mutex> lock(peerMutex_);
                            for (const auto& p : connectedPeers_) sendDisplayList(p.streamId);
                        }, Qt::QueuedConnection);
                    }
                }
                break;
            }
            case peariscope::ControlMessage::kPeerChallengeResponse: {
                auto& resp = control.peer_challenge_response();
                std::string pk;
                { std::lock_guard<std::mutex> lock(peerMutex_);
                  for (const auto& p : connectedPeers_) {
                      if (p.streamId == streamId) { pk = p.peerKeyHex; break; }
                  }
                }
                if (!pk.empty() && pendingPeerIds_.count(pk)) {
                    respondToPeerByKey(pk, streamId, resp.pin() == pinCode_);
                }
                break;
            }
            default: break;
            }
        } else if (mode_ == Mode::Viewing) {
            onViewerControlReceived(streamId, data, size);
        }
        break;
    case 3:
        if (audioDecoder_) audioDecoder_->Decode(data, static_cast<uint32_t>(size));
        break;
    }
}

void AppController::onConnectionFailed(const std::string& code,
                                        const std::string& reason,
                                        const std::string& errorType) {
    nativeLog("Connection failed: " + reason + " errorType=" + errorType);

    if (isReconnecting_) {
        // During auto-reconnect, the worklet already retried 3 times internally.
        // Count this as one reconnect attempt and try again.
        nativeLog("Connection failed during reconnect, will retry");
        return;
    }

    // Show meaningful error based on errorType
    if (errorType == "dht_timeout") {
        statusText_ = "Could not find host on the network";
    } else if (errorType == "holepunch_timeout") {
        statusText_ = "Host found but direct connection failed (NAT issue)";
    } else {
        statusText_ = "Connection failed: " + reason;
    }

    connectStatus_.clear();
    mode_ = Mode::Idle;

    if (wasHostingBeforeViewing_) {
        wasHostingBeforeViewing_ = false;
        QMetaObject::invokeMethod(this, [this]() { startHosting(); }, Qt::QueuedConnection);
        return;
    }

    emitUiUpdate();
}

// -----------------------------------------------------------------------
// Mode transitions
// -----------------------------------------------------------------------

void AppController::startHosting() {
    if (mode_ != Mode::Idle) return;

    mode_ = Mode::Hosting;
    statusText_ = "Starting host...";
    currentBitrate_ = kMaxBitrate;
    lowFpsReports_ = 0;
    goodFpsReports_ = 0;
    CrashLog::Log(CrashLog::Level::Info, "StartHosting");

    refreshDisplayList();

    uint32_t captureW = 1920, captureH = 1080;
    if (!availableDisplays_.empty()) {
        captureW = availableDisplays_[selectedDisplayIndex_].width;
        captureH = availableDisplays_[selectedDisplayIndex_].height;
    }

    inputInjector_ = std::make_unique<X11InputInjector>(captureW, captureH);
    ipcBridge_->StartHosting(savedCode_);

    fpsTimer_.start(1000);
    cursorTimer_.start(16);
    if (settings_.clipboardSync) {
        clipboardTimer_.start(1000);
    }

    emitUiUpdate();
}

void AppController::stopHosting() {
    if (mode_ != Mode::Hosting) return;

    if (avahiAdvertiser_) avahiAdvertiser_->Stop();
    fpsTimer_.stop();
    cursorTimer_.stop();
    clipboardTimer_.stop();

    ipcBridge_->StopHosting();
    ipcBridge_->blockedStreamIds.clear();
    approvedPeerKeys_.clear();

    if (audioCapture_) { audioCapture_->Stop(); audioCapture_.reset(); }
    if (audioEncoder_) { audioEncoder_->Stop(); audioEncoder_.reset(); }

    stopCapture();
    inputInjector_.reset();

    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        connectedPeers_.clear();
        peerKeySet_.clear();
    }
    pendingPeerIds_.clear();
    pendingPeerPin_.clear();
    pendingPeerKeyHex_.clear();

    mode_ = Mode::Idle;
    connectionCode_.clear();
    statusText_ = "Ready";
    emitUiUpdate();
    emit connectionCodeChanged();
}

void AppController::connectToHost(const QString& code) {
    std::string codeStr = code.toStdString();
    nativeLog("connectToHost called with code: '" + codeStr + "' mode=" + std::to_string(static_cast<int>(mode_)));
    if (codeStr.empty()) {
        nativeLog("connectToHost: empty code, ignoring");
        return;
    }
    if (mode_ == Mode::Hosting) {
        nativeLog("connectToHost: stopping hosting to switch to viewer");
        stopHosting();
    }
    if (mode_ != Mode::Idle && mode_ != Mode::Viewing) {
        nativeLog("connectToHost: wrong mode, ignoring");
        return;
    }

    mode_ = Mode::Viewing;
    lastConnectCode_ = codeStr;
    intentionalDisconnect_ = false;
    statusText_ = "Connecting...";
    saveRecentConnection(codeStr);
    emitUiUpdate();
    emit lastConnectCodeChanged();

    if (!ipcBridge_->IsAlive()) {
        ipcBridge_->Stop();
        ipcBridge_->Start();
    }

    ipcBridge_->ConnectToPeer(codeStr);
}

void AppController::disconnect() {
    if (mode_ != Mode::Viewing) return;

    intentionalDisconnect_ = true;
    isReconnecting_ = false;
    connectionLost_ = false;
    reconnectTimer_.stop();
    fpsTimer_.stop();
    qualityTimer_.stop();
    clipboardTimer_.stop();

    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        for (auto& peer : connectedPeers_)
            ipcBridge_->Disconnect(peer.peerKeyHex);
        connectedPeers_.clear();
        peerKeySet_.clear();
    }

    inputCapture_.reset();
    if (decoder_) decoder_->SetCallback(nullptr);
    decoder_.reset();
    renderer_.reset();

    if (audioDecoder_) { audioDecoder_->Stop(); audioDecoder_.reset(); }
    if (audioPlayer_) { audioPlayer_->Stop(); audioPlayer_.reset(); }

    mode_ = Mode::Idle;
    viewerPendingPin_.clear();
    viewerAwaitingPin_ = false;
    statusText_ = "Disconnected";

    exitViewerWindowMode();
    setPopupVisible(true);

    if (wasHostingBeforeViewing_) {
        wasHostingBeforeViewing_ = false;
        startHosting();
    }

    emitUiUpdate();
}

// -----------------------------------------------------------------------
// Viewer window (X11 + OpenGL)
// -----------------------------------------------------------------------

void AppController::enterViewerWindowMode() {
    if (isViewerWindow_) return;
    setPopupVisible(false);

    Display* dpy = XOpenDisplay(nullptr);
    if (!dpy) { statusText_ = "Cannot open X display"; return; }
    viewerDisplay_ = dpy;

    int screen = DefaultScreen(dpy);
    int w = 1280, h = 720;
    int x = (DisplayWidth(dpy, screen) - w) / 2;
    int y = (DisplayHeight(dpy, screen) - h) / 2;

    viewerWindow_ = XCreateSimpleWindow(dpy, RootWindow(dpy, screen),
        x, y, w, h, 0, BlackPixel(dpy, screen), BlackPixel(dpy, screen));

    // Set window title
    XStoreName(dpy, viewerWindow_, "Peariscope");

    // Register WM_DELETE_WINDOW protocol
    Atom wmDeleteMessage = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, viewerWindow_, &wmDeleteMessage, 1);

    // Select events
    XSelectInput(dpy, viewerWindow_,
        KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
        PointerMotionMask | StructureNotifyMask | ExposureMask);

    XMapWindow(dpy, viewerWindow_);
    XFlush(dpy);

    isViewerWindow_ = true;

    // Start event loop thread
    viewerEventRunning_ = true;
    viewerEventThread_ = std::thread(&AppController::viewerEventLoop, this);

    emit enterViewerMode();
}

void AppController::exitViewerWindowMode() {
    if (!isViewerWindow_) return;
    viewerEventRunning_ = false;
    if (viewerEventThread_.joinable()) viewerEventThread_.join();

    if (viewerDisplay_ && viewerWindow_) {
        XDestroyWindow(static_cast<Display*>(viewerDisplay_), viewerWindow_);
        viewerWindow_ = 0;
    }
    if (viewerDisplay_) {
        XCloseDisplay(static_cast<Display*>(viewerDisplay_));
        viewerDisplay_ = nullptr;
    }
    isViewerWindow_ = false;
    emit exitViewerMode();
}

void AppController::viewerEventLoop() {
    Display* dpy = static_cast<Display*>(viewerDisplay_);
    Atom wmDeleteMessage = XInternAtom(dpy, "WM_DELETE_WINDOW", False);

    while (viewerEventRunning_) {
        while (XPending(dpy) > 0) {
            XEvent event;
            XNextEvent(dpy, &event);

            if (event.type == ClientMessage &&
                static_cast<Atom>(event.xclient.data.l[0]) == wmDeleteMessage) {
                QMetaObject::invokeMethod(this, [this]() { disconnect(); }, Qt::QueuedConnection);
                viewerEventRunning_ = false;
                return;
            }

            if (event.type == ConfigureNotify) {
                // Window resized — update renderer output dimensions
                if (renderer_) renderer_->Resize(event.xconfigure.width, event.xconfigure.height);
            }

            if (inputCapture_ && mode_ == Mode::Viewing) {
                inputCapture_->ProcessEvent(&event);
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

void AppController::submitViewerPin(const QString& pin) {
    if (!viewerAwaitingPin_) return;
    std::string pinStr = pin.toStdString();
    if (pinStr.empty()) return;

    peariscope::ControlMessage resp;
    auto* pr = resp.mutable_peer_challenge_response();
    pr->set_pin(pinStr);
    pr->set_accepted(true);
    std::string serialized;
    if (resp.SerializeToString(&serialized)) {
        std::vector<uint8_t> data(serialized.begin(), serialized.end());
        sendControlData(data, viewerPinStreamId_);
    }

    viewerAwaitingPin_ = false;
    statusText_ = "PIN submitted, waiting for host...";
    emit viewerPinChanged();
    emit statusTextChanged();
}

// -----------------------------------------------------------------------
// Viewer pipeline
// -----------------------------------------------------------------------

void AppController::initViewerPipeline() {
    std::cout << "[viewer] initViewerPipeline starting" << std::endl;
    enterViewerWindowMode();

    if (!renderer_) {
        renderer_ = std::make_unique<GlRenderer>();
        if (!renderer_->Initialize(viewerDisplay_, viewerWindow_, 1920, 1080)) {
            statusText_ = "Failed to initialize renderer";
            mode_ = Mode::Idle;
            emitUiUpdate();
            return;
        }
    }

    if (!decoder_) {
        decoder_ = std::make_unique<FfmpegDecoder>();
        // Auto-detect codec (H.264 or H.265) from first video packet
        if (!decoder_->Initialize(1920, 1080)) {
            statusText_ = "Failed to initialize decoder";
            renderer_.reset();
            mode_ = Mode::Idle;
            emitUiUpdate();
            return;
        }
        decoder_->SetCallback([this](AVFrame* frame, uint64_t timestamp) {
            if (renderer_) {
                renderer_->Present(frame);
            }
            viewerFrameCount_++;
        });
        std::cout << "[viewer] Decoder initialized (auto-detect codec)" << std::endl;
    }

    if (!inputCapture_) {
        inputCapture_ = std::make_unique<X11InputCapture>();
        inputCapture_->Start(static_cast<Display*>(viewerDisplay_), viewerWindow_);
        inputCapture_->SetCallback([this](const X11InputCapture::InputEvent& event) {
            onLocalInput(event);
        });
    }

    if (!audioPlayer_) {
        audioPlayer_ = std::make_unique<PwAudioPlayer>();
        audioPlayer_->Start(48000, 2);
    }
    if (!audioDecoder_) {
        audioDecoder_ = std::make_unique<FfmpegAudioDecoder>();
        audioDecoder_->SetOnDecodedData([this](const float* data, uint32_t frames,
                                                uint32_t sr, uint32_t ch) {
            if (audioPlayer_) audioPlayer_->QueuePcm(data, frames);
        });
        audioDecoder_->Start(48000, 2);
    }

    fpsTimer_.start(1000);
    qualityTimer_.start(2000);
    if (settings_.clipboardSync) {
        // Delay clipboard sync to avoid sending data before handshake completes
        QTimer::singleShot(3000, this, [this]() {
            if (mode_ == Mode::Viewing && settings_.clipboardSync)
                clipboardTimer_.start(1000);
        });
    }
}

void AppController::onVideoReceived(uint32_t streamId, const uint8_t* data, size_t size) {
    static int videoLogCount = 0;

    // Detect NAL type (supports both H.264 and H.265)
    uint8_t firstNalByte = 0;
    bool isKeyframeOrParams = false;
    for (size_t i = 0; i + 4 < size && i < 32; i++) {
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) {
            firstNalByte = data[i+4];
            break;
        } else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            firstNalByte = data[i+3];
            break;
        }
    }

    // Check for keyframe/parameter NAL types in both codecs
    uint8_t h264type = firstNalByte & 0x1F;
    uint8_t h265type = (firstNalByte >> 1) & 0x3F;
    // H.264: SPS=7, PPS=8, IDR=5
    // H.265: VPS=32, SPS=33, PPS=34, IDR_W_RADL=19, IDR_N_LP=20, CRA=21
    if (h264type == 5 || h264type == 7 || h264type == 8 ||
        h265type >= 32 || h265type == 19 || h265type == 20 || h265type == 21) {
        isKeyframeOrParams = true;
    }

    if (videoLogCount < 10) {
        videoLogCount++;
        // Dump first 64 bytes hex + all NAL unit types found in packet
        std::ostringstream hexdump;
        hexdump << std::hex << std::setfill('0');
        for (size_t i = 0; i < std::min(size, (size_t)64); i++)
            hexdump << std::setw(2) << (int)data[i] << " ";

        // Find all NAL units in the packet
        std::ostringstream nalUnits;
        for (size_t i = 0; i + 4 < size; i++) {
            int scLen = 0;
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) scLen = 4;
            else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) scLen = 3;
            if (scLen > 0) {
                uint8_t nb = data[i + scLen];
                nalUnits << " @" << i << ":h265=" << ((nb >> 1) & 0x3F)
                         << "/h264=" << (nb & 0x1F);
                i += scLen; // skip past start code
            }
        }

        std::cout << "[video] onVideoReceived size=" << size
                  << " nalByte=0x" << std::hex << (int)firstNalByte << std::dec
                  << " h265type=" << (int)h265type
                  << (isKeyframeOrParams ? " [KEY]" : "")
                  << "\n  hex: " << hexdump.str()
                  << "\n  NALs:" << nalUnits.str() << std::endl;
    }
    if (!decoder_ || size < 5) return;

    // Validate: must contain an Annex B start code
    bool hasStartCode = false;
    for (size_t i = 0; i + 3 < size && i < 32; i++) {
        if ((data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) ||
            (i + 3 < size && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1)) {
            hasStartCode = true;
            break;
        }
    }
    if (!hasStartCode) return;

    // Never rate-limit keyframes or parameter sets (VPS/SPS/PPS) —
    // dropping these causes the decoder to fail until the next keyframe
    if (!isKeyframeOrParams) {
        if (pendingDecodes_.load() >= kMaxPendingDecodes) return;
        uint64_t now = MonotonicMs();
        if (now - lastDecodeTickMs_ < kMinDecodeIntervalMs) return;
        lastDecodeTickMs_ = now;
    }

    pendingDecodes_++;
    bool ok = decoder_->Decode(data, static_cast<uint32_t>(size));
    if (!ok && !isKeyframeOrParams) {
        // Decoder error on a non-keyframe — reset so it can recover on next keyframe
        decoder_->Reset();
    }
    // Request IDR after first successful auto-detect init
    static bool requestedPostInitIdr = false;
    if (!requestedPostInitIdr && decoder_->detectedCodec() != FfmpegDecoder::CodecType::Unknown) {
        requestedPostInitIdr = true;
        sendRequestIdr();
    }
    viewerFrameCount_++;
    pendingDecodes_--;
}

void AppController::onViewerControlReceived(uint32_t streamId, const uint8_t* data, size_t size) {
    peariscope::ControlMessage control;
    if (!control.ParseFromArray(data, static_cast<int>(size))) return;

    switch (control.msg_case()) {
    case peariscope::ControlMessage::kCodecNegotiation: {
        // Respond with our codec preference — support both H.264 and H.265
        peariscope::ControlMessage codecReply;
        auto* codec = codecReply.mutable_codec_negotiation();
        codec->add_supported_codecs(peariscope::CODEC_H264);
        codec->add_supported_codecs(peariscope::CODEC_H265);
        codec->set_selected_codec(peariscope::CODEC_H264);
        std::string serialized;
        if (codecReply.SerializeToString(&serialized)) {
            std::vector<uint8_t> d(serialized.begin(), serialized.end());
            sendControlData(d, streamId);
        }
        sendRequestIdr();
        break;
    }
    case peariscope::ControlMessage::kCursorPosition:
        remoteCursorX_ = control.cursor_position().x();
        remoteCursorY_ = control.cursor_position().y();
        break;
    case peariscope::ControlMessage::kPeerChallenge: {
        viewerPendingPin_ = control.peer_challenge().pin();
        viewerPinStreamId_ = streamId;
        viewerAwaitingPin_ = true;
        statusText_ = "PIN required";
        QMetaObject::invokeMethod(this, [this]() {
            setPopupVisible(true);
            emit viewerPinChanged();
            emit statusTextChanged();
        }, Qt::QueuedConnection);
        break;
    }
    case peariscope::ControlMessage::kPeerChallengeResponse:
        if (control.peer_challenge_response().accepted()) {
            viewerPendingPin_.clear();
            viewerAwaitingPin_ = false;
            statusText_ = "Connected to host";
            QMetaObject::invokeMethod(this, [this]() {
                setPopupVisible(false);
                // Send codec negotiation now that PIN is accepted
                {
                    peariscope::ControlMessage codecMsg;
                    auto* codec = codecMsg.mutable_codec_negotiation();
                    codec->add_supported_codecs(peariscope::CODEC_H264);
                    codec->add_supported_codecs(peariscope::CODEC_H265);
                    codec->set_selected_codec(peariscope::CODEC_H264);
                    std::string serialized;
                    if (codecMsg.SerializeToString(&serialized)) {
                        std::vector<uint8_t> d(serialized.begin(), serialized.end());
                        std::lock_guard<std::mutex> lock(peerMutex_);
                        for (const auto& peer : connectedPeers_)
                            sendControlData(d, peer.streamId);
                    }
                }
                emit statusTextChanged();
                emit viewerPinChanged();
            }, Qt::QueuedConnection);
        }
        break;
    case peariscope::ControlMessage::kClipboard:
        if (settings_.clipboardSync) applyRemoteClipboard(data, size);
        break;
    default: break;
    }
}

void AppController::onLocalInput(const X11InputCapture::InputEvent& event) {
    auto serialized = serializeInputEvent(event);
    if (serialized.empty()) return;
    std::lock_guard<std::mutex> lock(peerMutex_);
    for (auto& peer : connectedPeers_) {
        ipcBridge_->SendStreamData(peer.streamId,
            static_cast<uint8_t>(StreamCh::Input), serialized.data(), serialized.size());
    }
}

void AppController::sendQualityReport() {
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
    for (const auto& peer : connectedPeers_) sendControlData(data, peer.streamId);
}

void AppController::sendRequestIdr() {
    peariscope::ControlMessage control;
    control.mutable_request_idr();
    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    std::lock_guard<std::mutex> lock(peerMutex_);
    for (const auto& peer : connectedPeers_) sendControlData(data, peer.streamId);
}

void AppController::attemptReconnect() {
    if (lastConnectCode_.empty()) return;
    if (mode_ != Mode::Viewing) return;

    reconnectAttempts_++;
    if (reconnectAttempts_ > kMaxReconnectAttempts) {
        statusText_ = "Connection lost";
        isReconnecting_ = false;
        connectionLost_ = true;
        emit statusTextChanged();
        emit viewerStatsChanged();
        return;
    }

    // Linear backoff: 2s, 4s, 6s, 8s, 10s
    int delayMs = reconnectAttempts_ * 2000;

    isReconnecting_ = true;
    connectionLost_ = false;
    statusText_ = "Reconnecting (" + std::to_string(reconnectAttempts_) +
                  "/" + std::to_string(kMaxReconnectAttempts) + ")...";
    emit statusTextChanged();
    emit viewerStatsChanged();

    reconnectTimer_.setSingleShot(true);
    reconnectTimer_.start(delayMs);
    QObject::connect(&reconnectTimer_, &QTimer::timeout, this, [this]() {
        if (isReconnecting_ && mode_ == Mode::Viewing) {
            if (!ipcBridge_->IsAlive()) {
                ipcBridge_->Stop();
                ipcBridge_->Start();
            }
            ipcBridge_->ConnectToPeer(lastConnectCode_);
        }
    }, Qt::UniqueConnection);
}

void AppController::retryConnection() {
    if (lastConnectCode_.empty()) return;
    connectionLost_ = false;
    reconnectAttempts_ = 0;
    isReconnecting_ = false;
    emit viewerStatsChanged();
    attemptReconnect();
}

// -----------------------------------------------------------------------
// Host capture pipeline
// -----------------------------------------------------------------------

void AppController::startCapture() {
    if (isCaptureRunning_) return;
    isCaptureRunning_ = true;
    frameCount_ = 0;
    captureThreadRunning_ = true;
    captureThread_ = std::thread(&AppController::captureThreadFunc, this);
}

void AppController::stopCapture() {
    if (!isCaptureRunning_) return;
    captureThreadRunning_ = false;
    if (captureThread_.joinable()) captureThread_.join();
    // Shutdown capture first — its internal thread calls the frameCallback
    // which references encoder_. Must stop it before destroying the encoder.
    if (capture_) capture_->Shutdown();
    capture_.reset();
    encoder_.reset();
    isCaptureRunning_ = false;
}

void AppController::startAudioCapture() {
    if (!settings_.shareAudio || audioCapture_) return;
    audioCapture_ = std::make_unique<PwAudioCapture>();
    audioEncoder_ = std::make_unique<FfmpegAudioEncoder>();
    audioEncoder_->SetOnEncodedData([this](const uint8_t* data, uint32_t size) {
        std::lock_guard<std::mutex> lock(peerMutex_);
        for (auto& peer : connectedPeers_) {
            if (pendingPeerIds_.count(peer.peerKeyHex)) continue;
            ipcBridge_->SendStreamData(peer.streamId,
                static_cast<uint8_t>(StreamCh::Audio), data, size);
        }
    });
    audioEncoder_->Start(audioCapture_->GetSampleRate(), audioCapture_->GetChannels());
    audioCapture_->Start([this](const float* data, uint32_t frames,
                                uint32_t sr, uint32_t ch) {
        if (audioEncoder_) audioEncoder_->Encode(data, frames);
    });
}

void AppController::captureThreadFunc() {
    capture_ = std::make_unique<PipewireCapture>();
    capture_->SetFrameCallback([this](const uint8_t* data, uint32_t w, uint32_t h,
                                       uint32_t stride, uint64_t ts) {
        if (!captureThreadRunning_.load(std::memory_order_acquire)) return;
        if (!encoder_) return;
        encoder_->Encode(data, stride, ts);
        framesInSecond_++;
        uint32_t fc = frameCount_++;
        if (fc % 30 == 0) {
            QMetaObject::invokeMethod(this, [this]() { sendFrameTimestamp(); },
                Qt::QueuedConnection);
        }
    });
    if (!capture_->Initialize()) {
        statusText_ = "Failed to initialize screen capture";
        captureThreadRunning_ = false;
        return;
    }

    encoder_ = std::make_unique<FfmpegEncoder>();
    if (!encoder_->Initialize(capture_->GetWidth(), capture_->GetHeight(), 30, 4000000)) {
        statusText_ = "Failed to initialize encoder";
        capture_.reset();
        captureThreadRunning_ = false;
        return;
    }
    encoder_->SetCallback([this](const uint8_t* data, size_t size, bool isKeyframe) {
        onEncodedFrame(data, size, isKeyframe);
    });

    // PipewireCapture is push-based, just wait for stop signal
    while (captureThreadRunning_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void AppController::onEncodedFrame(const uint8_t* data, size_t size, bool isKeyframe) {
    std::lock_guard<std::mutex> lock(peerMutex_);
    for (auto& peer : connectedPeers_) {
        if (pendingPeerIds_.count(peer.peerKeyHex)) continue;
        if (isKeyframe) {
            // Log keyframe details — first 5 bytes show NAL type
            uint8_t nalType = (size > 4) ? (data[4] & 0x1F) : 0;
            nativeLog("KEYFRAME to " + peer.peerKeyHex.substr(0,8) + " size=" +
                      std::to_string(size) + " NAL=" + std::to_string(nalType));
        }
        ipcBridge_->SendStreamData(peer.streamId,
            static_cast<uint8_t>(StreamCh::Video), data, size);
    }
}

void AppController::forceKeyframe() {
    if (encoder_) encoder_->ForceKeyframe();
}

// -----------------------------------------------------------------------
// Host control messages
// -----------------------------------------------------------------------

void AppController::sendCursorPosition() {
    if (!viewerDisplay_) {
        // Use the default display for cursor query on host
        Display* dpy = XOpenDisplay(nullptr);
        if (!dpy) return;
        Window root = DefaultRootWindow(dpy);
        Window child;
        int rootX, rootY, winX, winY;
        unsigned int mask;
        if (!XQueryPointer(dpy, root, &root, &child, &rootX, &rootY, &winX, &winY, &mask)) {
            XCloseDisplay(dpy);
            return;
        }
        uint32_t dispW = 1920, dispH = 1080;
        if (capture_) { dispW = capture_->GetWidth(); dispH = capture_->GetHeight(); }
        float nx = std::clamp(static_cast<float>(rootX) / dispW, 0.0f, 1.0f);
        float ny = std::clamp(static_cast<float>(rootY) / dispH, 0.0f, 1.0f);
        XCloseDisplay(dpy);

        float dx = nx - lastCursorX_, dy = ny - lastCursorY_;
        if (dx * dx + dy * dy < 0.0000001f) return;
        lastCursorX_ = nx; lastCursorY_ = ny;

        peariscope::ControlMessage control;
        auto* cursor = control.mutable_cursor_position();
        cursor->set_x(nx); cursor->set_y(ny);
        std::string serialized;
        if (!control.SerializeToString(&serialized)) return;
        std::vector<uint8_t> data(serialized.begin(), serialized.end());
        sendControlDataToAll(data);
        return;
    }

    Display* dpy = static_cast<Display*>(viewerDisplay_);
    Window root = DefaultRootWindow(dpy);
    Window child;
    int rootX, rootY, winX, winY;
    unsigned int mask;
    if (!XQueryPointer(dpy, root, &root, &child, &rootX, &rootY, &winX, &winY, &mask)) return;

    uint32_t dispW = 1920, dispH = 1080;
    if (capture_) { dispW = capture_->GetWidth(); dispH = capture_->GetHeight(); }
    float nx = std::clamp(static_cast<float>(rootX) / dispW, 0.0f, 1.0f);
    float ny = std::clamp(static_cast<float>(rootY) / dispH, 0.0f, 1.0f);
    float dx = nx - lastCursorX_, dy = ny - lastCursorY_;
    if (dx * dx + dy * dy < 0.0000001f) return;
    lastCursorX_ = nx; lastCursorY_ = ny;

    peariscope::ControlMessage control;
    auto* cursor = control.mutable_cursor_position();
    cursor->set_x(nx); cursor->set_y(ny);
    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    sendControlDataToAll(data);
}

void AppController::sendCodecNegotiation(uint32_t streamId) {
    peariscope::ControlMessage control;
    auto* codec = control.mutable_codec_negotiation();
    codec->add_supported_codecs(peariscope::CODEC_H264);
    codec->add_supported_codecs(peariscope::CODEC_H265);
    codec->set_selected_codec(peariscope::CODEC_H264);
    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    sendControlData(data, streamId);
}

void AppController::sendDisplayList(uint32_t streamId) {
    peariscope::ControlMessage control;
    auto* dl = control.mutable_display_list();
    for (size_t i = 0; i < availableDisplays_.size(); ++i) {
        auto* info = dl->add_displays();
        info->set_display_id(static_cast<uint32_t>(i));
        info->set_width(availableDisplays_[i].width);
        info->set_height(availableDisplays_[i].height);
        // Linux display names are already UTF-8
        info->set_name(availableDisplays_[i].name);
        info->set_is_active(i == selectedDisplayIndex_);
    }
    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    sendControlData(data, streamId);
}

void AppController::sendFrameTimestamp() {
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
    sendControlDataToAll(data);
}

void AppController::sendControlData(const std::vector<uint8_t>& data, uint32_t streamId) {
    ipcBridge_->SendStreamData(streamId, static_cast<uint8_t>(StreamCh::Control),
        data.data(), data.size());
}

void AppController::sendControlDataToAll(const std::vector<uint8_t>& data) {
    std::lock_guard<std::mutex> lock(peerMutex_);
    for (const auto& peer : connectedPeers_) {
        if (pendingPeerIds_.count(peer.peerKeyHex)) continue;
        sendControlData(data, peer.streamId);
    }
}

// -----------------------------------------------------------------------
// PIN verification
// -----------------------------------------------------------------------

void AppController::sendPinChallenge(const std::string& peerKeyHex, uint32_t streamId) {
    peariscope::ControlMessage control;
    auto* challenge = control.mutable_peer_challenge();
    // Security: do NOT send the actual PIN — only the peer key for fingerprint display.
    // The viewer must enter the PIN shown on the host screen.
    std::string peerKeyBytes;
    for (size_t i = 0; i + 1 < peerKeyHex.size(); i += 2) {
        uint8_t byte = static_cast<uint8_t>(std::stoi(peerKeyHex.substr(i, 2), nullptr, 16));
        peerKeyBytes.push_back(static_cast<char>(byte));
    }
    challenge->set_peer_key(peerKeyBytes);
    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    sendControlData(data, streamId);
}

void AppController::respondToPeer(bool accepted) {
    if (pendingPeerKeyHex_.empty()) return;
    std::string peerKey = pendingPeerKeyHex_;
    uint32_t streamId = 0;
    {
        std::lock_guard<std::mutex> lock(peerMutex_);
        for (const auto& p : connectedPeers_) {
            if (p.peerKeyHex == peerKey) { streamId = p.streamId; break; }
        }
    }
    pendingPeerKeyHex_.clear();
    pendingPeerPin_.clear();
    respondToPeerByKey(peerKey, streamId, accepted);
}

void AppController::respondToPeerByKey(const std::string& peerKey, uint32_t streamId, bool accepted) {
    pendingPeerIds_.erase(peerKey);
    if (streamId > 0) ipcBridge_->blockedStreamIds.erase(streamId);
    if (pendingPeerKeyHex_ == peerKey) {
        pendingPeerKeyHex_.clear();
        pendingPeerPin_.clear();
    }

    if (accepted && streamId > 0) {
        approvedPeerKeys_.insert(peerKey);
        peariscope::ControlMessage control;
        auto* resp = control.mutable_peer_challenge_response();
        resp->set_pin(pinCode_);
        resp->set_accepted(true);
        std::string serialized;
        if (control.SerializeToString(&serialized)) {
            std::vector<uint8_t> data(serialized.begin(), serialized.end());
            sendControlData(data, streamId);
        }
        // Start streaming + audio
        QMetaObject::invokeMethod(this, [this, streamId]() {
            if (!isCaptureRunning_) startCapture();
            startAudioCapture();
            sendCodecNegotiation(streamId);
            sendDisplayList(streamId);
            // Force keyframes — encoder may not be ready yet if startCapture() just launched.
            // The encoder itself starts with forceKeyframe_=true, but send extras to be safe.
            forceKeyframe();
            QTimer::singleShot(500, this, [this]() { forceKeyframe(); });
            QTimer::singleShot(1000, this, [this]() { forceKeyframe(); });
            QTimer::singleShot(2000, this, [this]() { forceKeyframe(); });
            QTimer::singleShot(5000, this, [this]() { forceKeyframe(); });
            QTimer::singleShot(10000, this, [this]() { forceKeyframe(); });
        }, Qt::QueuedConnection);
    } else if (!accepted) {
        ipcBridge_->Disconnect(peerKey);
    }

    emitUiUpdate();
    emit pendingPeerChanged();
}

// -----------------------------------------------------------------------
// Protobuf serialization
// -----------------------------------------------------------------------

std::vector<uint8_t> AppController::serializeInputEvent(const X11InputCapture::InputEvent& event) {
    peariscope::InputEvent pb;
    pb.set_timestamp_ms(static_cast<uint32_t>(MonotonicMs() & 0xFFFFFFFF));
    switch (event.type) {
    case X11InputCapture::InputEvent::KEY: {
        auto* key = pb.mutable_key();
        key->set_keycode(event.keycode);
        key->set_modifiers(event.modifiers);
        key->set_pressed(event.pressed);
        break;
    }
    case X11InputCapture::InputEvent::MOUSE_MOVE: {
        auto* move = pb.mutable_mouse_move();
        move->set_x(event.x); move->set_y(event.y);
        break;
    }
    case X11InputCapture::InputEvent::MOUSE_BUTTON: {
        auto* btn = pb.mutable_mouse_button();
        btn->set_button(event.button);
        btn->set_pressed(event.pressed);
        btn->set_x(event.x); btn->set_y(event.y);
        break;
    }
    case X11InputCapture::InputEvent::SCROLL: {
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

void AppController::deserializeAndInjectInput(const uint8_t* data, size_t size) {
    if (!inputInjector_) return;
    peariscope::InputEvent pb;
    if (!pb.ParseFromArray(data, static_cast<int>(size))) return;
    switch (pb.event_case()) {
    case peariscope::InputEvent::kKey: {
        auto& key = pb.key();
        uint32_t keycode = key.keycode();
        // Linux injector handles VK -> keysym mapping internally
        inputInjector_->InjectKey(keycode, key.modifiers(), key.pressed());
        break;
    }
    case peariscope::InputEvent::kMouseMove:
        inputInjector_->InjectMouseMove(pb.mouse_move().x(), pb.mouse_move().y());
        break;
    case peariscope::InputEvent::kMouseButton:
        inputInjector_->InjectMouseButton(pb.mouse_button().button(),
            pb.mouse_button().pressed(), pb.mouse_button().x(), pb.mouse_button().y());
        break;
    case peariscope::InputEvent::kScroll:
        inputInjector_->InjectScroll(pb.scroll().delta_x(), pb.scroll().delta_y());
        break;
    default: break;
    }
}

// -----------------------------------------------------------------------
// Settings
// -----------------------------------------------------------------------

std::filesystem::path AppController::settingsDir() {
    const char* home = std::getenv("HOME");
    if (!home) home = "/tmp";
    auto dir = std::filesystem::path(home) / ".config" / "peariscope";
    std::filesystem::create_directories(dir);
    return dir;
}

void AppController::applySettings() {
    requirePin_ = settings_.pinProtection;

    // Load PIN from encrypted storage (KeyManager), with one-time migration
    // from plaintext settings file (matches iOS Keychain migration pattern).
    if (keyManager_) {
        std::string securePin = keyManager_->LoadPin();
        if (securePin.empty() && !settings_.pinCode.isEmpty() && settings_.pinCode != "000000") {
            // Migrate plaintext PIN to encrypted storage
            keyManager_->SavePin(settings_.pinCode.toStdString());
            securePin = settings_.pinCode.toStdString();
            nativeLog("[security] Migrated PIN from plaintext settings to encrypted storage");
            // Clear from plaintext file
            settings_.pinCode = "";
            saveSettings();
        }
        if (!securePin.empty()) {
            pinCode_ = securePin;
            // Keep settings_.pinCode in sync for UI display
            settings_.pinCode = QString::fromStdString(securePin);
        } else {
            pinCode_ = settings_.pinCode.toStdString();
        }
    } else {
        pinCode_ = settings_.pinCode.toStdString();
    }

    if (mode_ == Mode::Hosting) {
        if (settings_.shareAudio && !audioCapture_) {
            startAudioCapture();
        } else if (!settings_.shareAudio && audioCapture_) {
            audioCapture_->Stop(); audioCapture_.reset();
            audioEncoder_->Stop(); audioEncoder_.reset();
        }

        if (settings_.clipboardSync) clipboardTimer_.start(1000);
        else clipboardTimer_.stop();
    }

    // Run on startup via XDG autostart
    const char* home = std::getenv("HOME");
    if (home) {
        auto autostartDir = std::filesystem::path(home) / ".config" / "autostart";
        auto desktopFile = autostartDir / "peariscope.desktop";
        if (settings_.runOnStartup) {
            std::filesystem::create_directories(autostartDir);
            char exePath[PATH_MAX]{};
            ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
            if (len > 0) {
                exePath[len] = '\0';
                std::ofstream f(desktopFile);
                if (f.is_open()) {
                    f << "[Desktop Entry]\n";
                    f << "Type=Application\n";
                    f << "Name=Peariscope\n";
                    f << "Exec=" << exePath << "\n";
                    f << "X-GNOME-Autostart-enabled=true\n";
                }
            }
        } else {
            std::filesystem::remove(desktopFile);
        }
    }
}

// -----------------------------------------------------------------------
// Display management
// -----------------------------------------------------------------------

void AppController::refreshDisplayList() {
    availableDisplays_ = PipewireCapture::EnumerateDisplays();
    if (selectedDisplayIndex_ >= availableDisplays_.size()) selectedDisplayIndex_ = 0;
}

// -----------------------------------------------------------------------
// Persistent connection code
// -----------------------------------------------------------------------

std::string AppController::savedCodePath() {
    return (settingsDir() / "peariscope-code.txt").string();
}

std::string AppController::loadSavedCode() {
    std::ifstream f(savedCodePath());
    if (!f.is_open()) return {};
    std::string code;
    std::getline(f, code);
    int words = 0;
    for (char c : code) if (c == ' ') words++;
    if (words != 11 || code.empty()) return {};
    return code;
}

void AppController::saveCode(const std::string& code) {
    std::ofstream f(savedCodePath());
    if (f.is_open()) f << code;
}

// -----------------------------------------------------------------------
// Recent connections
// -----------------------------------------------------------------------

std::string AppController::recentConnectionsPath() {
    return (settingsDir() / "peariscope-recent.txt").string();
}

void AppController::loadRecentConnections() {
    recentEntries_.clear();
    std::ifstream f(recentConnectionsPath());
    if (!f.is_open()) return;
    std::string line;
    while (std::getline(f, line)) {
        RecentEntry rc;
        auto p1 = line.find('|');
        if (p1 == std::string::npos) continue;
        rc.pinned = (line.substr(0, p1) == "1");
        auto p2 = line.find('|', p1 + 1);
        if (p2 == std::string::npos) continue;
        rc.timestamp = line.substr(p1 + 1, p2 - p1 - 1);
        auto p3 = line.find('|', p2 + 1);
        if (p3 == std::string::npos) continue;
        rc.name = line.substr(p2 + 1, p3 - p2 - 1);
        rc.code = line.substr(p3 + 1);
        if (!rc.code.empty()) recentEntries_.push_back(std::move(rc));
    }

    // Sync to model
    QVector<RecentConnection> items;
    for (const auto& e : recentEntries_) {
        items.push_back({
            QString::fromStdString(e.code),
            QString::fromStdString(e.name),
            QString::fromStdString(e.timestamp),
            e.pinned, e.onlineStatus
        });
    }
    recentModel_.setItems(items);
}

void AppController::saveRecentConnectionsFile() {
    std::ofstream f(recentConnectionsPath());
    if (f.is_open()) {
        for (const auto& r : recentEntries_) {
            f << (r.pinned ? "1" : "0") << "|"
              << r.timestamp << "|" << r.name << "|" << r.code << "\n";
        }
    }
    // Sync to model
    QVector<RecentConnection> items;
    for (const auto& e : recentEntries_) {
        items.push_back({
            QString::fromStdString(e.code),
            QString::fromStdString(e.name),
            QString::fromStdString(e.timestamp),
            e.pinned, e.onlineStatus
        });
    }
    recentModel_.setItems(items);
}

void AppController::saveRecentConnection(const std::string& code) {
    if (code.empty()) return;
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M", std::localtime(&t));

    for (auto it = recentEntries_.begin(); it != recentEntries_.end(); ++it) {
        if (it->code == code) {
            auto existing = *it;
            recentEntries_.erase(it);
            existing.timestamp = buf;
            auto pos = recentEntries_.begin();
            while (pos != recentEntries_.end() && pos->pinned) ++pos;
            recentEntries_.insert(pos, existing);
            saveRecentConnectionsFile();
            return;
        }
    }

    RecentEntry rc;
    rc.code = code;
    rc.timestamp = buf;
    auto pos = recentEntries_.begin();
    while (pos != recentEntries_.end() && pos->pinned) ++pos;
    recentEntries_.insert(pos, rc);
    while (recentEntries_.size() > kMaxRecentConnections) {
        for (auto it = recentEntries_.rbegin(); it != recentEntries_.rend(); ++it) {
            if (!it->pinned) { recentEntries_.erase(std::next(it).base()); break; }
        }
    }
    saveRecentConnectionsFile();
}

void AppController::deleteRecentConnection(int index) {
    if (index < 0 || index >= static_cast<int>(recentEntries_.size())) return;
    recentEntries_.erase(recentEntries_.begin() + index);
    saveRecentConnectionsFile();
}

void AppController::renameRecentConnection(int index, const QString& name) {
    if (index < 0 || index >= static_cast<int>(recentEntries_.size())) return;
    recentEntries_[index].name = name.toStdString();
    saveRecentConnectionsFile();
}

void AppController::togglePinRecentConnection(int index) {
    if (index < 0 || index >= static_cast<int>(recentEntries_.size())) return;
    recentEntries_[index].pinned = !recentEntries_[index].pinned;
    std::stable_sort(recentEntries_.begin(), recentEntries_.end(),
        [](const RecentEntry& a, const RecentEntry& b) { return a.pinned > b.pinned; });
    saveRecentConnectionsFile();
}

void AppController::probeRecentConnectionStatus() {
    if (!ipcBridge_ || recentEntries_.empty()) return;
    for (auto& rc : recentEntries_) {
        rc.onlineStatus = 0;
        ipcBridge_->LookupPeer(rc.code);
    }
}

// -----------------------------------------------------------------------
// Clipboard sync
// -----------------------------------------------------------------------

void AppController::checkClipboardChanged() {
    // Use Qt clipboard monitoring — check if clipboard text/image has changed
    // by comparing content (Qt handles clipboard ownership tracking)
    static QString lastText;
    auto* clipboard = QGuiApplication::clipboard();
    QString currentText = clipboard->text();
    if (currentText != lastText) {
        lastText = currentText;
        if (suppressNextClipboard_) { suppressNextClipboard_ = false; return; }
        sendClipboardToAll();
    }
}

void AppController::sendClipboardToAll() {
    if (connectedPeers_.empty()) return;
    auto pngData = readClipboardImage();
    std::string textData;
    if (pngData.empty()) textData = readClipboardText();
    if (pngData.empty() && textData.empty()) return;

    peariscope::ClipboardData clipMsg;
    if (!pngData.empty()) {
        if (pngData.size() > kMaxClipboardImage) return;
        clipMsg.set_image_png(pngData.data(), pngData.size());
    } else {
        if (textData.size() > kMaxClipboardText) return;
        clipMsg.set_text(textData);
    }

    peariscope::ControlMessage control;
    *control.mutable_clipboard() = clipMsg;
    std::string serialized;
    if (!control.SerializeToString(&serialized)) return;
    std::vector<uint8_t> data(serialized.begin(), serialized.end());
    sendControlDataToAll(data);
}

std::string AppController::readClipboardText() {
    auto* clipboard = QGuiApplication::clipboard();
    return clipboard->text().toStdString();
}

std::vector<uint8_t> AppController::readClipboardImage() {
    auto* clipboard = QGuiApplication::clipboard();
    QImage image = clipboard->image();
    if (image.isNull()) return {};

    QByteArray ba;
    QBuffer buffer(&ba);
    buffer.open(QIODevice::WriteOnly);
    if (!image.save(&buffer, "PNG")) return {};
    return std::vector<uint8_t>(ba.begin(), ba.end());
}

void AppController::applyRemoteClipboard(const uint8_t* data, size_t size) {
    peariscope::ControlMessage control;
    if (!control.ParseFromArray(data, static_cast<int>(size))) return;
    if (!control.has_clipboard()) return;
    const auto& clip = control.clipboard();

    if (!clip.text().empty()) {
        const auto& text = clip.text();
        if (text.size() > kMaxClipboardText) return;
        auto* clipboard = QGuiApplication::clipboard();
        suppressNextClipboard_ = true;
        clipboard->setText(QString::fromStdString(text));
    } else if (!clip.image_png().empty()) {
        const auto& pngData = clip.image_png();
        if (pngData.size() > kMaxClipboardImage) return;
        QImage image;
        if (image.loadFromData(reinterpret_cast<const uchar*>(pngData.data()),
                                static_cast<int>(pngData.size()), "PNG")) {
            auto* clipboard = QGuiApplication::clipboard();
            suppressNextClipboard_ = true;
            clipboard->setImage(image);
        }
    }
}

} // namespace peariscope
