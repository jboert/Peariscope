#include "NetworkMonitor.h"
#include <QDBusConnection>
#include <iostream>

namespace peariscope {

// NetworkManager connectivity states:
// 0 = Unknown, 10 = Asleep, 20 = Disconnected, 30 = Disconnecting,
// 40 = Connecting, 50 = Connected (local), 60 = Connected (site),
// 70 = Connected (global)
static constexpr uint NM_STATE_CONNECTED_GLOBAL = 70;

NetworkMonitor::NetworkMonitor(QObject* parent) : QObject(parent) {
    QDBusConnection systemBus = QDBusConnection::systemBus();

    if (!systemBus.isConnected()) {
        std::cerr << "[NetworkMonitor] Cannot connect to D-Bus system bus" << std::endl;
        return;
    }

    // Subscribe to org.freedesktop.NetworkManager::StateChanged(uint)
    bool ok = systemBus.connect(
        "org.freedesktop.NetworkManager",              // service
        "/org/freedesktop/NetworkManager",             // path
        "org.freedesktop.NetworkManager",              // interface
        "StateChanged",                                // signal name
        this,                                          // receiver
        SLOT(onStateChanged(uint))                     // slot
    );

    if (!ok) {
        std::cerr << "[NetworkMonitor] Failed to connect to NetworkManager StateChanged signal" << std::endl;
    }
}

NetworkMonitor::~NetworkMonitor() = default;

void NetworkMonitor::onStateChanged(uint state) {
    std::cerr << "[NetworkMonitor] NM state changed: " << lastState_ << " -> " << state << std::endl;

    // Fire callback when transitioning TO connected state
    if (state >= NM_STATE_CONNECTED_GLOBAL && lastState_ < NM_STATE_CONNECTED_GLOBAL) {
        std::cerr << "[NetworkMonitor] Network connectivity restored" << std::endl;
        if (onNetworkUp) onNetworkUp();
    }

    lastState_ = state;
}

} // namespace peariscope
