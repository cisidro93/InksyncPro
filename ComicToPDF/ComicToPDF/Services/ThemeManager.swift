import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
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
    
    // UI Helpers
    static var background: Color {
        Color(UIColor.systemGroupedBackground)
    }
    
    static var surface: Color {
        Color(UIColor.secondarySystemGroupedBackground)
    }
}

class ThemeManager: ObservableObject {
    @AppStorage("selectedTheme") private var selectedThemeRaw: String = AppTheme.system.rawValue
    
    @Published var selectedTheme: AppTheme = .system {
        didSet {
            selectedThemeRaw = selectedTheme.rawValue
        }
    }
    
    init() {
        if let theme = AppTheme(rawValue: selectedThemeRaw) {
            selectedTheme = theme
        }
    }
    
    // Dynamic colors that adapt to theme
    static func primaryColor(for colorScheme: ColorScheme?) -> Color {
        return .orange
    }
    
    static func secondaryColor(for colorScheme: ColorScheme?) -> Color {
        return .blue
    }
    
    static func backgroundColor(for colorScheme: ColorScheme?) -> Color {
        return Color(UIColor.systemGroupedBackground)
    }
    
    static func surfaceColor(for colorScheme: ColorScheme?) -> Color {
        return Color(UIColor.secondarySystemGroupedBackground)
    }
    
    static func textColor(for colorScheme: ColorScheme?) -> Color {
        return Color(UIColor.label)
    }
    
    static func secondaryTextColor(for colorScheme: ColorScheme?) -> Color {
        return Color(UIColor.secondaryLabel)
    }
    
    static func gradient(for colorScheme: ColorScheme?) -> LinearGradient {
        LinearGradient(
            colors: [Color.orange.opacity(0.1), Color.blue.opacity(0.05), Color.clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
