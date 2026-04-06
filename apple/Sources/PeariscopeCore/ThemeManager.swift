import SwiftUI

public enum AppTheme: String, CaseIterable, Identifiable {
    case peariscope = "peariscope"
    case berriscope = "berriscope"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .peariscope: return "Peariscope"
        case .berriscope: return "Berriscope"
        }
    }

    public var accentColor: Color {
        switch self {
        case .peariscope: return Color("PearGreen")
        case .berriscope: return Color("GrapePurple")
        }
    }

    public var accentDim: Color { accentColor.opacity(0.12) }
    public var accentGlow: Color { accentColor.opacity(0.25) }

    public var gradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var logoImageName: String {
        switch self {
        case .peariscope: return "AppLogo"
        case .berriscope: return "GrapeLogo"
        }
    }

    /// iOS alternate icon name (nil = default)
    public var alternateIconName: String? {
        switch self {
        case .peariscope: return nil
        case .berriscope: return "BerriscopeIcon"
        }
    }
}

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    @Published public var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "peariscope.theme")
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "peariscope.theme") ?? "peariscope"
        self.current = AppTheme(rawValue: saved) ?? .peariscope
    }
}
