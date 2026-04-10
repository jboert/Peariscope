#include "SleepWakeMonitor.h"
#include <QDBusConnection>
#include <QDBusInterface>
#include <iostream>

namespace peariscope {

SleepWakeMonitor::SleepWakeMonitor(QObject* parent) : QObject(parent) {
    QDBusConnection systemBus = QDBusConnection::systemBus();

    if (!systemBus.isConnected()) {
        std::cerr << "[SleepWakeMonitor] Cannot connect to D-Bus system bus" << std::endl;
        return;
    }

    // Subscribe to org.freedesktop.login1.Manager::PrepareForSleep(bool)
    bool ok = systemBus.connect(
        "org.freedesktop.login1",           // service
        "/org/freedesktop/login1",          // path
        "org.freedesktop.login1.Manager",   // interface
        "PrepareForSleep",                  // signal name
        this,                               // receiver
        SLOT(onPrepareForSleep(bool))       // slot
    );

    if (!ok) {
        std::cerr << "[SleepWakeMonitor] Failed to connect to PrepareForSleep signal" << std::endl;
    }
}

SleepWakeMonitor::~SleepWakeMonitor() = default;

void SleepWakeMonitor::onPrepareForSleep(bool suspending) {
    if (suspending) {
        std::cerr << "[SleepWakeMonitor] System entering sleep" << std::endl;
        if (onSleep) onSleep();
    } else {
        std::cerr << "[SleepWakeMonitor] System waking up" << std::endl;
        if (onWake) onWake();
    }
}

} // namespace peariscope
