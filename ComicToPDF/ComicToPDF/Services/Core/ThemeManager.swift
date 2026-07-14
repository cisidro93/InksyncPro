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

class ThemeManager: ObservableObject {
    @AppStorage("selectedTheme") var selectedTheme: AppearanceMode = .system
}

enum SidebarPlacement: String, CaseIterable, Identifiable, Codable {
    case left = "Left"
    case right = "Right"
    
    var id: String { rawValue }
}
