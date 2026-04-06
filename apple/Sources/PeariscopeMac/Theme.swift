import SwiftUI
import PeariscopeCore

// MARK: - Theme

extension Color {
    @MainActor static var pearGreen: Color { ThemeManager.shared.current.accentColor }
    @MainActor static var pearGreenDim: Color { ThemeManager.shared.current.accentDim }
    @MainActor static var pearGlow: Color { ThemeManager.shared.current.accentGlow }
    static let surfaceElevated = Color(.controlBackgroundColor)
}

extension ShapeStyle where Self == LinearGradient {
    @MainActor static var pearGradient: LinearGradient {
        ThemeManager.shared.current.gradient
    }
}
