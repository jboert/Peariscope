#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Pear Theme

extension Color {
    static let pearGreen = Color("PearGreen")
    static let pearGreenDim = Color("PearGreen").opacity(0.12)
    static let pearGlow = Color("PearGreen").opacity(0.25)
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
