import SwiftUI

// Renamed to avoid conflict with existing AppTheme struct
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

class ThemeManager: ObservableObject {
    @AppStorage("selectedTheme") private var selectedThemeRaw: String = AppearanceTheme.system.rawValue
    
    @Published var selectedTheme: AppearanceTheme = .system {
        didSet {
            selectedThemeRaw = selectedTheme.rawValue
        }
    }
    
    init() {
        if let theme = AppearanceTheme(rawValue: selectedThemeRaw) {
            selectedTheme = theme
        }
    }
}
