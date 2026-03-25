import SwiftUI

// MARK: - Core Preference Data Engine
class EBookPreferences: ObservableObject {
    static let shared = EBookPreferences()
    
    // Theme
    @AppStorage("ebook_theme") var themeRaw: String = EBookTheme.auto.rawValue
    
    // Typography
    @AppStorage("ebook_fontSize") var fontSize: Double = 18
    @AppStorage("ebook_fontFamily") var fontFamily: String = EBookFontFamily.literata.rawValue
    @AppStorage("ebook_lineHeight") var lineHeight: Double = 1.5
    @AppStorage("ebook_textAlign") var textAlign: String = EBookTextAlign.justify.rawValue
    
    // Layout
    @AppStorage("ebook_textMargin") var textMargin: Double = 20
    @AppStorage("ebook_paraIndent") var paragraphIndent: Double = 1.2 // em
    @AppStorage("ebook_paraSpacing") var paragraphSpacing: Double = 0.5 // em
    
    // Reading Mode
    @AppStorage("ebook_pagination") var paginationMode: String = EBookPaginationMode.paged.rawValue
    
    var activeTheme: EBookTheme { EBookTheme(rawValue: themeRaw) ?? .auto }
}

enum EBookTheme: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case light = "Day"
    case sepia = "Sepia"
    case dark = "Night"
    case obsidian = "Obsidian" // Pure OLED black
    
    var id: String { rawValue }
    
    // The rendered background color for Swift Views
    func background(colorScheme: ColorScheme) -> Color {
        if self == .auto { return colorScheme == .dark ? Color(hex: "#141414") : Color(hex: "#FAFAFA") }
        switch self {
        case .light: return Color(hex: "#FAFAFA")
        case .sepia: return Color(hex: "#F5EDD6")
        case .dark: return Color(hex: "#1C1C1E")
        case .obsidian: return Color.black
        default: return Color(hex: "#FAFAFA")
        }
    }
    
    func foreground(colorScheme: ColorScheme) -> Color {
        if self == .auto { return colorScheme == .dark ? Color(hex: "#E8E0D5") : Color(hex: "#1A1A1A") }
        switch self {
        case .light: return Color(hex: "#1A1A1A")
        case .sepia: return Color(hex: "#3B2D1F")
        case .dark: return Color(hex: "#E8E0D5")
        case .obsidian: return Color(hex: "#CCCCCC")
        default: return Color(hex: "#1A1A1A")
        }
    }
    
    // The CSS injected rendered color
    func cssBackground(colorScheme: ColorScheme) -> String {
        if self == .auto { return colorScheme == .dark ? "#141414" : "#FAFAFA" }
        switch self {
        case .light: return "#FAFAFA"
        case .sepia: return "#F5EDD6"
        case .dark: return "#1C1C1E"
        case .obsidian: return "#000000"
        default: return "#FAFAFA"
        }
    }
    
    func cssText(colorScheme: ColorScheme) -> String {
        if self == .auto { return colorScheme == .dark ? "#E8E0D5" : "#1A1A1A" }
        switch self {
        case .light: return "#1A1A1A"
        case .sepia: return "#3B2D1F"
        case .dark: return "#E8E0D5"
        case .obsidian: return "#CCCCCC"
        default: return "#1A1A1A"
        }
    }
    
    func cssLink(colorScheme: ColorScheme) -> String {
        if self == .auto { return colorScheme == .dark ? "#B39DDB" : "#7B5EA7" }
        switch self {
        case .light, .sepia: return "#7B5EA7"
        case .dark, .obsidian: return "#B39DDB"
        default: return "#7B5EA7"
        }
    }
}

enum EBookFontFamily: String, CaseIterable, Identifiable {
    case literata = "Georgia, serif"
    case system = "-apple-system, sans-serif"
    case athelas = "Athelas, serif"
    case palatino = "Palatino, serif"
    case openDyslexic = "OpenDyslexic, sans-serif"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .literata: return "Literata"
        case .system: return "System"
        case .athelas: return "Athelas"
        case .palatino: return "Palatino"
        case .openDyslexic: return "OpenDyslexic"
        }
    }
}

enum EBookTextAlign: String, CaseIterable, Identifiable {
    case justify = "justify"
    case left = "left"
    case right = "right"
    var id: String { rawValue }
}

enum EBookPaginationMode: String, CaseIterable, Identifiable {
    case paged = "Paged"
    case continuous = "Scroll"
    var id: String { rawValue }
}
