#pragma once

#include <QObject>
#include <QDBusConnection>
#include <functional>

namespace peariscope {

/// Monitors NetworkManager D-Bus signals to detect network connectivity changes.
class NetworkMonitor : public QObject {
    Q_OBJECT

public:
    explicit NetworkMonitor(QObject* parent = nullptr);
    ~NetworkMonitor() override;

    /// Called when network connectivity is restored (NM state >= 70 / connected)
    std::function<void()> onNetworkUp;

private slots:
    void onStateChanged(uint state);

private:
    uint lastState_ = 0;
};

} // namespace peariscope
