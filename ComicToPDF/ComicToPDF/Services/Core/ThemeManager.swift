import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var id: String { rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Reader Canvas Theme Tokens
struct ReaderCanvasThemeTokens: Sendable {
    let pageTint: Color?
    let canvasBackground: Color
    let gutterColor: Color
    let isDark: Bool
}

@MainActor
enum ReaderCanvasTheme {
    static func tokens(for theme: EBookTheme) -> ReaderCanvasThemeTokens {
        switch theme {
        case .paper:
            return ReaderCanvasThemeTokens(
                pageTint: nil,
                canvasBackground: Color(hex: "#F5F5F7"),
                gutterColor: Color(hex: "#E5E5EA"),
                isDark: false
            )
        case .parchment:
            return ReaderCanvasThemeTokens(
                pageTint: Color(hex: "#FBF7EF"),
                canvasBackground: Color(hex: "#F4EDE0"),
                gutterColor: Color(hex: "#E8DFC8"),
                isDark: false
            )
        case .sepia:
            return ReaderCanvasThemeTokens(
                pageTint: Color(hex: "#F8F0E3"),
                canvasBackground: Color(hex: "#EADCC8"),
                gutterColor: Color(hex: "#DFCEB5"),
                isDark: false
            )
        case .slate:
            return ReaderCanvasThemeTokens(
                pageTint: Color(hex: "#E2EAF2"),
                canvasBackground: Color(hex: "#D2DDE8"),
                gutterColor: Color(hex: "#C2D0DD"),
                isDark: false
            )
        case .night:
            return ReaderCanvasThemeTokens(
                pageTint: nil,
                canvasBackground: Color(hex: "#0D0D0D"),
                gutterColor: Color(hex: "#1A1A1A"),
                isDark: true
            )
        case .oled:
            return ReaderCanvasThemeTokens(
                pageTint: nil,
                canvasBackground: Color(hex: "#000000"),
                gutterColor: Color(hex: "#111111"),
                isDark: true
            )
        case .custom:
            let bg = Color(hex: EBookPreferences.shared.customThemeBg)
            return ReaderCanvasThemeTokens(
                pageTint: bg,
                canvasBackground: bg.opacity(0.85),
                gutterColor: bg.opacity(0.65),
                isDark: theme.isDark
            )
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @AppStorage("selectedTheme") var selectedTheme: AppearanceMode = .system
}

enum SidebarPlacement: String, CaseIterable, Identifiable, Codable {
    case left = "Left"
    case right = "Right"
    
    var id: String { rawValue }
}
