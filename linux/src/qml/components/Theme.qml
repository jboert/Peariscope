pragma Singleton
import QtQuick

QtObject {
    id: theme

    // Available accent colors (index into this list is stored in settings)
    readonly property var accentColors: [
        "#9BE238",  // Pear Green (default) — matches Mac
        "#9B61DE",  // Grape Purple
        "#0A84FF",  // Blue
        "#FF9F0A",  // Orange
        "#FF453A",  // Red
        "#30D158",  // Mint
        "#BF5AF2",  // Violet
        "#FFD60A",  // Yellow
    ]

    readonly property var accentNames: [
        "Pear", "Grape", "Blue", "Orange", "Red", "Mint", "Violet", "Yellow"
    ]

    property int colorIndex: 0

    // Derived accent values
    readonly property color accent: accentColors[colorIndex] || accentColors[0]
    readonly property color accentDim: Qt.rgba(accent.r, accent.g, accent.b, 0.12)
    readonly property color accentGlow: Qt.rgba(accent.r, accent.g, accent.b, 0.25)
    readonly property color accentHover: Qt.lighter(accent, 1.1)
    readonly property color accentPress: Qt.darker(accent, 1.15)

    // Focus border (used on text inputs)
    readonly property color focusBorder: Qt.rgba(accent.r, accent.g, accent.b, 0.3)

    // Background & surface
    readonly property color bg: "#1e1e1e"
    readonly property color surface: Qt.rgba(1, 1, 1, 0.04)
    readonly property color surfaceBorder: Qt.rgba(1, 1, 1, 0.08)
    readonly property color separator: Qt.rgba(1, 1, 1, 0.08)

    // Text hierarchy
    readonly property color textPrimary: "#ffffff"
    readonly property color textSecondary: Qt.rgba(1, 1, 1, 0.65)
    readonly property color textTertiary: Qt.rgba(1, 1, 1, 0.45)
    readonly property color textQuaternary: Qt.rgba(1, 1, 1, 0.25)
    readonly property color textOnAccent: "#141414"

    // Button defaults
    readonly property color buttonBg: Qt.rgba(1, 1, 1, 0.07)
    readonly property color buttonHover: Qt.rgba(1, 1, 1, 0.12)
    readonly property color buttonPress: Qt.rgba(1, 1, 1, 0.04)

    // Icon tint
    readonly property color iconDim: Qt.rgba(1, 1, 1, 0.55)

    // Fonts — use generic families so the system picks the best available
    readonly property string fontFamily: "sans-serif"
    readonly property string monoFamily: "monospace"
}
