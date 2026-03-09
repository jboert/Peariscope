#include "HostWindow.h"

#include <algorithm>

namespace peariscope {

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------
static constexpr int kPadding        = 24;
static constexpr int kCodeFontSize   = 36;
static constexpr int kLabelFontSize  = 16;
static constexpr int kStatusFontSize = 14;
static constexpr int kButtonHeight   = 40;
static constexpr int kButtonWidth    = 160;
static constexpr int kQrPlaceholder  = 160;   // square side length

// Colors
static constexpr COLORREF kBgColor       = RGB(30, 30, 30);
static constexpr COLORREF kTextColor     = RGB(230, 230, 230);
static constexpr COLORREF kCodeColor     = RGB(100, 220, 100);
static constexpr COLORREF kButtonBg      = RGB(180, 50, 50);
static constexpr COLORREF kButtonText    = RGB(255, 255, 255);
static constexpr COLORREF kQrBorder      = RGB(80, 80, 80);
static constexpr COLORREF kStatusColor   = RGB(160, 160, 160);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void HostWindow::SetConnectionCode(const std::string& code) {
    connectionCode_ = code;
}

void HostWindow::SetPeerCount(uint32_t count) {
    peerCount_ = count;
}

void HostWindow::SetStatus(const std::string& status) {
    status_ = status;
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

void HostWindow::Draw(HDC hdc, const RECT& rect) const {
    // Background
    HBRUSH bgBrush = CreateSolidBrush(kBgColor);
    FillRect(hdc, &rect, bgBrush);
    DeleteObject(bgBrush);

    SetBkMode(hdc, TRANSPARENT);

    int cx = (rect.left + rect.right) / 2;
    int y  = rect.top + kPadding;

    // ---- Title label ----
    HFONT labelFont = CreateFontW(
        kLabelFontSize, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HFONT oldFont = static_cast<HFONT>(SelectObject(hdc, labelFont));
    SetTextColor(hdc, kTextColor);

    const wchar_t* title = L"Hosting Session";
    RECT titleRect = { rect.left, y, rect.right, y + kLabelFontSize + 4 };
    DrawTextW(hdc, title, -1, &titleRect, DT_CENTER | DT_SINGLELINE);
    y += kLabelFontSize + kPadding;

    // ---- Connection code (large) ----
    HFONT codeFont = CreateFontW(
        kCodeFontSize, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_MODERN, L"Consolas");
    SelectObject(hdc, codeFont);
    SetTextColor(hdc, kCodeColor);

    std::wstring codeW(connectionCode_.begin(), connectionCode_.end());
    if (codeW.empty()) codeW = L"------";
    RECT codeRect = { rect.left, y, rect.right, y + kCodeFontSize + 8 };
    DrawTextW(hdc, codeW.c_str(), -1, &codeRect, DT_CENTER | DT_SINGLELINE);
    y += kCodeFontSize + kPadding;

    // ---- QR code placeholder ----
    int qrLeft = cx - kQrPlaceholder / 2;
    int qrTop  = y;
    RECT qrRect = { qrLeft, qrTop, qrLeft + kQrPlaceholder, qrTop + kQrPlaceholder };

    HBRUSH qrBrush = CreateSolidBrush(kBgColor);
    FillRect(hdc, &qrRect, qrBrush);
    DeleteObject(qrBrush);

    HPEN qrPen = CreatePen(PS_SOLID, 1, kQrBorder);
    HPEN oldPen = static_cast<HPEN>(SelectObject(hdc, qrPen));
    HBRUSH nullBrush = static_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
    HBRUSH oldBrush = static_cast<HBRUSH>(SelectObject(hdc, nullBrush));
    Rectangle(hdc, qrRect.left, qrRect.top, qrRect.right, qrRect.bottom);
    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(qrPen);

    // "QR Code" placeholder text
    SelectObject(hdc, labelFont);
    SetTextColor(hdc, kQrBorder);
    DrawTextW(hdc, L"QR Code", -1, &qrRect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    y = qrRect.bottom + kPadding;

    // ---- Connected peers ----
    SetTextColor(hdc, kTextColor);
    wchar_t peerBuf[64];
    wsprintfW(peerBuf, L"Connected peers: %u", peerCount_);
    RECT peerRect = { rect.left, y, rect.right, y + kLabelFontSize + 4 };
    DrawTextW(hdc, peerBuf, -1, &peerRect, DT_CENTER | DT_SINGLELINE);
    y += kLabelFontSize + 8;

    // ---- Status text ----
    HFONT statusFont = CreateFontW(
        kStatusFontSize, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    SelectObject(hdc, statusFont);
    SetTextColor(hdc, kStatusColor);

    std::wstring statusW(status_.begin(), status_.end());
    RECT statusRect = { rect.left, y, rect.right, y + kStatusFontSize + 4 };
    DrawTextW(hdc, statusW.c_str(), -1, &statusRect, DT_CENTER | DT_SINGLELINE);
    y += kStatusFontSize + kPadding;

    // ---- Stop Hosting button ----
    int btnLeft = cx - kButtonWidth / 2;
    int btnTop  = y;
    stopButtonRect_ = { btnLeft, btnTop, btnLeft + kButtonWidth, btnTop + kButtonHeight };

    HBRUSH btnBrush = CreateSolidBrush(kButtonBg);
    FillRect(hdc, &stopButtonRect_, btnBrush);
    DeleteObject(btnBrush);

    HFONT btnFont = CreateFontW(
        kLabelFontSize, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    SelectObject(hdc, btnFont);
    SetTextColor(hdc, kButtonText);
    DrawTextW(hdc, L"Stop Hosting", -1, &stopButtonRect_,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    // Cleanup fonts
    SelectObject(hdc, oldFont);
    DeleteObject(labelFont);
    DeleteObject(codeFont);
    DeleteObject(statusFont);
    DeleteObject(btnFont);
}

// ---------------------------------------------------------------------------
// HitTest
// ---------------------------------------------------------------------------

HostHit HostWindow::HitTest(POINT pt) const {
    if (PtInRect(&stopButtonRect_, pt)) {
        return HostHit::StopHosting;
    }
    return HostHit::None;
}

} // namespace peariscope
