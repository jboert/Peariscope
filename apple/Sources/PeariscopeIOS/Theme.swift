#if os(iOS)
import SwiftUI
import UIKit
import PeariscopeCore

// MARK: - Pear Theme

extension Color {
    @MainActor static var pearGreen: Color { ThemeManager.shared.current.accentColor }
    @MainActor static var pearGreenDim: Color { ThemeManager.shared.current.accentDim }
    @MainActor static var pearGlow: Color { ThemeManager.shared.current.accentGlow }
}

extension ShapeStyle where Self == LinearGradient {
    @MainActor static var pearGradient: LinearGradient {
        ThemeManager.shared.current.gradient
    }
}

// MARK: - [13] Orientation Lock

class AppOrientationLock {
    nonisolated(unsafe) static var orientationLock: UIInterfaceOrientationMask = .all

    static func lock(_ orientation: UIInterfaceOrientationMask) {
        orientationLock = orientation
        if #available(iOS 16.0, *) {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            let geometryPreferences: UIWindowScene.GeometryPreferences
            switch orientation {
            case .landscape:
                geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            case .all:
                geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .all)
            default:
                geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
            }
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                NSLog("[orientation] Failed to update geometry: %@", error.localizedDescription)
            }
        }
    }
}
#endif
