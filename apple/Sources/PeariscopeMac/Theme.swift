import SwiftUI

// MARK: - Theme

extension Color {
    static let pearGreen = Color("PearGreen")
    static let pearGreenDim = Color("PearGreen").opacity(0.12)
    static let pearGlow = Color("PearGreen").opacity(0.25)
    static let surfaceElevated = Color(.controlBackgroundColor)
}

extension ShapeStyle where Self == LinearGradient {
    static var pearGradient: LinearGradient {
        LinearGradient(
            colors: [Color.pearGreen, Color.pearGreen.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
