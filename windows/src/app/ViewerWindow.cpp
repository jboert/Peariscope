#include "ViewerWindow.h"

#include <algorithm>

namespace peariscope {

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------
static constexpr int kPadding         = 24;
static constexpr int kTitleFontSize   = 20;
static constexpr int kLabelFontSize   = 14;
static constexpr int kInputFontSize   = 24;
static constexpr int kButtonHeight    = 40;
static constexpr int kButtonWidth     = 140;
static constexpr int kInputWidth      = 280;
static constexpr int kInputHeight     = 38;
static constexpr int kMaxCodeLength   = 32;

// Colors
static constexpr COLORREF kBgColor        = RGB(30, 30, 30);
static constexpr COLORREF kTextColor      = RGB(230, 230, 230);
static constexpr COLORREF kPlaceholder    = RGB(100, 100, 100);
static constexpr COLORREF kInputBg        = RGB(50, 50, 50);
static constexpr COLORREF kInputBorder    = RGB(100, 100, 100);
static constexpr COLORREF kInputFocusBdr  = RGB(80, 180, 80);
static constexpr COLORREF kConnectBtnBg   = RGB(50, 140, 50);
static constexpr COLORREF kDisconnectBg   = RGB(180, 50, 50);
static constexpr COLORREF kButtonText     = RGB(255, 255, 255);
static constexpr COLORREF kStatusColor    = RGB(160, 160, 160);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void ViewerWindow::SetConnected(bool connected) {
    connected_ = connected;
}

void ViewerWindow::SetStatus(const std::string& status) {
    status_ = status;
}

void ViewerWindow::OnChar(wchar_t ch) {
    if (connected_) return;

    // Accept printable ASCII only (alphanumeric, dashes, etc.)
    if (ch >= 0x20 && ch < 0x7F) {
        if (static_cast<int>(enteredCode_.size()) < kMaxCodeLength) {
            enteredCode_ += ch;
        }
    }
}

void ViewerWindow::OnKeyDown(WPARAM vk) {
    if (connected_) return;

    if (vk == VK_BACK && !enteredCode_.empty()) {
        enteredCode_.pop_back();
    }
}

std::string ViewerWindow::GetEnteredCode() const {
    return std::string(enteredCode_.begin(), enteredCode_.end());
}

void ViewerWindow::ClearEnteredCode() {
    enteredCode_.clear();
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

void ViewerWindow::Draw(HDC hdc, const RECT& rect) const {
    // When connected the D3DRenderer handles everything.
    if (connected_) {
        // Reset cached rects so HitTest returns None for stale positions.
        connectButtonRect_    = {};
        codeInputRect_        = {};
        disconnectButtonRect_ = {};
        return;
    }

    // Background
    HBRUSH bgBrush = CreateSolidBrush(kBgColor);
    FillRect(hdc, &rect, bgBrush);
    DeleteObject(bgBrush);

    SetBkMode(hdc, TRANSPARENT);

    int cx = (rect.left + rect.right) / 2;
    int cy = (rect.top + rect.bottom) / 2;

    // We center the dialog vertically. Compute total height of elements.
    //   title + padding + label + padding + input + padding + button + padding + status
    int totalH = kTitleFontSize + kPadding + kLabelFontSize + 8 + kInputHeight
                 + kPadding + kButtonHeight + kPadding + kLabelFontSize;
    int y = cy - totalH / 2;

    // ---- Title ----
    HFONT titleFont = CreateFontW(
        kTitleFontSize, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HFONT oldFont = static_cast<HFONT>(SelectObject(hdc, titleFont));
    SetTextColor(hdc, kTextColor);

    RECT titleRect = { rect.left, y, rect.right, y + kTitleFontSize + 4 };
    DrawTextW(hdc, L"Connect to Host", -1, &titleRect, DT_CENTER | DT_SINGLELINE);
    y += kTitleFontSize + kPadding;

    // ---- "Connection code" label ----
    HFONT labelFont = CreateFontW(
        kLabelFontSize, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    SelectObject(hdc, labelFont);
    SetTextColor(hdc, kTextColor);

    RECT lblRect = { rect.left, y, rect.right, y + kLabelFontSize + 4 };
    DrawTextW(hdc, L"Enter connection code:", -1, &lblRect, DT_CENTER | DT_SINGLELINE);
    y += kLabelFontSize + 8;

    // ---- Text input field ----
    int inputLeft = cx - kInputWidth / 2;
    codeInputRect_ = { inputLeft, y, inputLeft + kInputWidth, y + kInputHeight };

    // Input background
    HBRUSH inputBg = CreateSolidBrush(kInputBg);
    FillRect(hdc, &codeInputRect_, inputBg);
    DeleteObject(inputBg);

    // Input border
    COLORREF borderColor = enteredCode_.empty() ? kInputBorder : kInputFocusBdr;
    HPEN borderPen = CreatePen(PS_SOLID, 1, borderColor);
    HPEN oldPen = static_cast<HPEN>(SelectObject(hdc, borderPen));
    HBRUSH nullBrush = static_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
    HBRUSH oldBrush = static_cast<HBRUSH>(SelectObject(hdc, nullBrush));
    Rectangle(hdc, codeInputRect_.left, codeInputRect_.top,
              codeInputRect_.right, codeInputRect_.bottom);
    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(borderPen);

    // Input text or placeholder
    HFONT inputFont = CreateFontW(
        kInputFontSize, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_MODERN, L"Consolas");
    SelectObject(hdc, inputFont);

    RECT textInset = codeInputRect_;
    textInset.left  += 8;
    textInset.right -= 8;

    if (enteredCode_.empty()) {
        SetTextColor(hdc, kPlaceholder);
        DrawTextW(hdc, L"ABC-1234", -1, &textInset,
                  DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    } else {
        SetTextColor(hdc, kTextColor);
        // Draw with a blinking-cursor-like pipe character appended.
        std::wstring display = enteredCode_ + L"|";
        DrawTextW(hdc, display.c_str(), -1, &textInset,
                  DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    }
    y = codeInputRect_.bottom + kPadding;

    // ---- Connect button ----
    int btnLeft = cx - kButtonWidth / 2;
    connectButtonRect_ = { btnLeft, y, btnLeft + kButtonWidth, y + kButtonHeight };

    HBRUSH btnBrush = CreateSolidBrush(kConnectBtnBg);
    FillRect(hdc, &connectButtonRect_, btnBrush);
    DeleteObject(btnBrush);

    HFONT btnFont = CreateFontW(
        kLabelFontSize, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    SelectObject(hdc, btnFont);
    SetTextColor(hdc, kButtonText);
    DrawTextW(hdc, L"Connect", -1, &connectButtonRect_,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    y = connectButtonRect_.bottom + kPadding;

    // ---- Status text ----
    if (!status_.empty()) {
        SelectObject(hdc, labelFont);
        SetTextColor(hdc, kStatusColor);
        std::wstring statusW(status_.begin(), status_.end());
        RECT statusRect = { rect.left, y, rect.right, y + kLabelFontSize + 4 };
        DrawTextW(hdc, statusW.c_str(), -1, &statusRect, DT_CENTER | DT_SINGLELINE);
    }

    // Cleanup fonts
    SelectObject(hdc, oldFont);
    DeleteObject(titleFont);
    DeleteObject(labelFont);
    DeleteObject(inputFont);
    DeleteObject(btnFont);
}

// ---------------------------------------------------------------------------
// HitTest
// ---------------------------------------------------------------------------

ViewerHit ViewerWindow::HitTest(POINT pt) const {
    if (!connected_) {
        if (PtInRect(&connectButtonRect_, pt)) {
            return ViewerHit::Connect;
        }
        if (PtInRect(&codeInputRect_, pt)) {
            return ViewerHit::CodeInput;
        }
    } else {
        if (PtInRect(&disconnectButtonRect_, pt)) {
            return ViewerHit::Disconnect;
        }
    }
    return ViewerHit::None;
}

} // namespace peariscope
