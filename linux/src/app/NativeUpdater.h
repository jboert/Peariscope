#pragma once

#include <QObject>
#include <QString>
#include <string>
#include <functional>
#include <atomic>

namespace peariscope {

/// Handles native binary OTA updates received from the worklet
/// via the Hyperdrive-based update system.
class NativeUpdater : public QObject {
    Q_OBJECT

public:
    explicit NativeUpdater(QObject* parent = nullptr);
    ~NativeUpdater() override;

    /// Called when worklet reports an update is available.
    void OnUpdateAvailable(const std::string& version,
                           const std::string& downloadPath,
                           const std::string& component);

    /// Apply the pending update (relaunch with new binary).
    void ApplyUpdate();

    bool HasPendingUpdate() const { return hasPendingUpdate_.load(); }
    std::string PendingVersion() const { return pendingVersion_; }
    std::string PendingComponent() const { return pendingComponent_; }

signals:
    void updateReady(const QString& version, const QString& component);

private:
    std::atomic<bool> hasPendingUpdate_{false};
    std::string pendingVersion_;
    std::string pendingDownloadPath_;
    std::string pendingComponent_;
};

} // namespace peariscope
