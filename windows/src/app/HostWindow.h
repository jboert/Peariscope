#pragma once

#include <Windows.h>
#include <string>
#include <cstdint>

namespace peariscope {

/// Hit-test results for the host UI panel.
enum class HostHit {
    None,
    StopHosting,
};

/// Lightweight helper that draws the host-mode UI within the main App window.
/// Does NOT own a top-level window; the App calls Draw() during WM_PAINT and
/// forwards mouse clicks through HitTest().
class HostWindow {
public:
    HostWindow() = default;
    ~HostWindow() = default;

    // Non-copyable, non-movable (holds no resources worth moving).
    HostWindow(const HostWindow&) = delete;
    HostWindow& operator=(const HostWindow&) = delete;

    /// Set the connection code that viewers use to connect.
    void SetConnectionCode(const std::string& code);

    /// Update the count of currently connected peers.
    void SetPeerCount(uint32_t count);

    /// Set a status message shown below the peer count.
    void SetStatus(const std::string& status);

    /// Draw the entire host UI into the given device context, clipped to rect.
    void Draw(HDC hdc, const RECT& rect) const;

    /// Returns which interactive element, if any, contains the given point.
    HostHit HitTest(POINT pt) const;

private:
    std::string connectionCode_;
    uint32_t peerCount_ = 0;
    std::string status_ = "Hosting";

    // Cached button rectangle (set during Draw, used during HitTest).
    mutable RECT stopButtonRect_ = {};
};

} // namespace peariscope
