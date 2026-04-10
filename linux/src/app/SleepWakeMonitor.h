#pragma once

#include <QObject>
#include <QDBusConnection>
#include <functional>

namespace peariscope {

/// Monitors D-Bus PrepareForSleep signals from systemd-logind
/// to detect sleep/wake transitions.
class SleepWakeMonitor : public QObject {
    Q_OBJECT

public:
    explicit SleepWakeMonitor(QObject* parent = nullptr);
    ~SleepWakeMonitor() override;

    std::function<void()> onSleep;
    std::function<void()> onWake;

private slots:
    void onPrepareForSleep(bool suspending);
};

} // namespace peariscope
