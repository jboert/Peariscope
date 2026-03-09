#pragma once

#include <Windows.h>
#include <string>

namespace peariscope {

/// Hit-test results for the viewer UI panel.
enum class ViewerHit {
    None,
    Connect,
    Disconnect,
    CodeInput,
};

/// Lightweight helper that draws the viewer / connect UI within the main
/// App window.  When not yet connected it shows a connection-code input and a
/// Connect button.  Once connected the D3DRenderer takes over and this class
/// only draws a small Disconnect overlay when requested.
class ViewerWindow {
public:
    ViewerWindow() = default;
    ~ViewerWindow() = default;

    ViewerWindow(const ViewerWindow&) = delete;
    ViewerWindow& operator=(const ViewerWindow&) = delete;

    /// Mark whether we are currently connected to a remote host.
    void SetConnected(bool connected);
    bool IsConnected() const { return connected_; }

    /// Set a status / error message.
    void SetStatus(const std::string& status);

    /// Draw the viewer UI.  When connected this is a no-op (the renderer
    /// draws the remote desktop).  When disconnected it draws the connect
    /// dialog.
    void Draw(HDC hdc, const RECT& rect) const;

    /// Returns which interactive element, if any, contains the given point.
    ViewerHit HitTest(POINT pt) const;

    /// Feed a WM_CHAR character into the connection-code text field.
    void OnChar(wchar_t ch);

    /// Feed a WM_KEYDOWN virtual-key into the text field (handles backspace,
    /// etc.)
    void OnKeyDown(WPARAM vk);

    /// Return the connection code the user has typed so far.
    std::string GetEnteredCode() const;

    /// Clear the entered code.
    void ClearEnteredCode();

private:
    bool connected_ = false;
    std::wstring enteredCode_;
    std::string status_;

    // Cached interactive rectangles (written during Draw, read during HitTest).
    mutable RECT connectButtonRect_ = {};
    mutable RECT disconnectButtonRect_ = {};
    mutable RECT codeInputRect_ = {};
};

} // namespace peariscope
