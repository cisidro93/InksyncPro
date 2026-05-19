import SwiftUI

// MARK: - Core Preference Data Engine
class EBookPreferences: ObservableObject {
    static let shared = EBookPreferences()

    // MARK: - Theme
    @AppStorage("ebook_theme") var themeRaw: String = EBookTheme.paper.rawValue

    // Per-book theme memory: [bookID: themeRaw]
    @AppStorage("ebook_bookThemes") private var bookThemesData: Data = Data()
    var bookThemes: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: bookThemesData)) ?? [:] }
        set { bookThemesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    // Custom theme slot
    @AppStorage("ebook_customThemeBg")   var customThemeBg: String   = "#FFFFFF"
    @AppStorage("ebook_customThemeText") var customThemeText: String  = "#1A1A1A"

    // MARK: - Typography
    @AppStorage("ebook_fontFamily")     var fontFamily: String  = EBookFontFamily.newYork.rawValue
    @AppStorage("ebook_fontSize")       var fontSize: Double    = 18
    @AppStorage("ebook_lineHeight")     var lineHeight: Double  = 1.6
    @AppStorage("ebook_letterSpacing")  var letterSpacing: Double = 0.0   // em
    @AppStorage("ebook_wordSpacing")    var wordSpacing: Double   = 0.0   // em
    @AppStorage("ebook_textAlign")      var textAlign: String   = EBookTextAlign.justify.rawValue
    @AppStorage("ebook_hyphenation")    var hyphenation: Bool   = true

    // Per-book typography lock: [bookID: JSON-encoded BookTypographyProfile]
    @AppStorage("ebook_bookTypography") private var bookTypographyData: Data = Data()
    var bookTypographyProfiles: [String: BookTypographyProfile] {
        get { (try? JSONDecoder().decode([String: BookTypographyProfile].self, from: bookTypographyData)) ?? [:] }
        set { bookTypographyData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    // MARK: - Layout
    @AppStorage("ebook_textMargin")     var textMargin: Double      = 24
    @AppStorage("ebook_paraIndent")     var paragraphIndent: Double = 1.2  // em
    @AppStorage("ebook_paraSpacing")    var paragraphSpacing: Double = 0.5 // em

    // MARK: - Reading Mode
    @AppStorage("ebook_pagination")     var paginationMode: String = EBookPaginationMode.paged.rawValue

    // MARK: - Reader Features
    @AppStorage("ebook_readingRuler")   var showReadingRuler: Bool  = false
    @AppStorage("ebook_rulerYPosition") var rulerYPosition: Double  = 0.4   // fraction of screen height
    @AppStorage("ebook_autoScroll")     var autoScroll: Bool        = false
    @AppStorage("ebook_autoScrollSpeed") var autoScrollSpeed: Double = 1.0  // multiplier

    // Progress display mode (cycles on tap)
    @AppStorage("ebook_progressMode")   var progressMode: Int = 0  // 0=page, 1=chapter, 2=timeLeft

    // MARK: - Image Filters (legacy, kept for compatibility)
    @AppStorage("ebook_isSmartCropEnabled") var isSmartCropEnabled: Bool = false
    @AppStorage("ebook_autoContrastLevel")  var autoContrastLevel: Double = 1.0
    @AppStorage("ebook_saturationLevel")    var saturationLevel: Double = 1.0
    @AppStorage("ebook_warmthLevel")        var warmthLevel: Double = 0.0

    // MARK: - Active theme helpers
    var activeTheme: EBookTheme { EBookTheme(rawValue: themeRaw) ?? .paper }

    /// Apply a book's saved theme if it exists, otherwise use the global theme.
    func applyBookTheme(bookID: String) {
        if let saved = bookThemes[bookID] {
            themeRaw = saved
        }
    }

    /// Apply a book's saved typography profile if it exists.
    func applyBookTypography(bookID: String) {
        guard let profile = bookTypographyProfiles[bookID] else { return }
        fontFamily      = profile.fontFamily
        fontSize        = profile.fontSize
        lineHeight      = profile.lineHeight
        letterSpacing   = profile.letterSpacing
        wordSpacing     = profile.wordSpacing
        textAlign       = profile.textAlign
        hyphenation     = profile.hyphenation
        textMargin      = profile.textMargin
        paragraphIndent = profile.paragraphIndent
        paragraphSpacing = profile.paragraphSpacing
    }

    /// Save all current typography settings for a specific book.
    func lockTypographyForBook(_ bookID: String) {
        var profiles = bookTypographyProfiles
        profiles[bookID] = BookTypographyProfile(
            fontFamily:       fontFamily,
            fontSize:         fontSize,
            lineHeight:       lineHeight,
            letterSpacing:    letterSpacing,
            wordSpacing:      wordSpacing,
            textAlign:        textAlign,
            hyphenation:      hyphenation,
            textMargin:       textMargin,
            paragraphIndent:  paragraphIndent,
            paragraphSpacing: paragraphSpacing
        )
        bookTypographyProfiles = profiles
    }

    func unlockTypographyForBook(_ bookID: String) {
        var profiles = bookTypographyProfiles
        profiles.removeValue(forKey: bookID)
        bookTypographyProfiles = profiles
    }

    func isTypographyLockedForBook(_ bookID: String) -> Bool {
        bookTypographyProfiles[bookID] != nil
    }
}

// MARK: - Per-Book Typography Profile
struct BookTypographyProfile: Codable {
    var fontFamily: String
    var fontSize: Double
    var lineHeight: Double
    var letterSpacing: Double
    var wordSpacing: Double
    var textAlign: String
    var hyphenation: Bool
    var textMargin: Double
    var paragraphIndent: Double
    var paragraphSpacing: Double
}

// MARK: - Theme Engine
enum EBookTheme: String, CaseIterable, Identifiable {
    case paper     = "Paper"
    case parchment = "Parchment"
    case sepia     = "Sepia"
    case slate     = "Slate"
    case night     = "Night"
    case custom    = "Custom"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var background: Color {
        switch self {
        case .paper:     return Color(hex: "#FFFFFF")
        case .parchment: return Color(hex: "#FBF7EF")
        case .sepia:     return Color(hex: "#F8F0E3")
        case .slate:     return Color(hex: "#1A2332")
        case .night:     return Color(hex: "#0D0D0D")
        case .custom:    return Color(hex: EBookPreferences.shared.customThemeBg)
        }
    }

    var text: Color {
        switch self {
        case .paper:     return Color(hex: "#1A1A1A")
        case .parchment: return Color(hex: "#3D2B1F")
        case .sepia:     return Color(hex: "#5C4033")
        case .slate:     return Color(hex: "#E8ECF0")
        case .night:     return Color(hex: "#CCCCCC")
        case .custom:    return Color(hex: EBookPreferences.shared.customThemeText)
        }
    }

    var accent: Color {
        switch self {
        case .paper:     return Color(hex: "#7B5EA7")
        case .parchment: return Color(hex: "#8B6914")
        case .sepia:     return Color(hex: "#A0522D")
        case .slate:     return Color(hex: "#6EA4D0")
        case .night:     return Color(hex: "#FF7B2C")
        case .custom:    return Color(hex: "#7B5EA7")
        }
    }

    var isDark: Bool {
        switch self {
        case .slate, .night: return true
        default: return false
        }
    }

    // CSS colour values
    func cssBackground(colorScheme: ColorScheme) -> String { cssBackground }
    var cssBackground: String {
        switch self {
        case .paper:     return "#FFFFFF"
        case .parchment: return "#FBF7EF"
        case .sepia:     return "#F8F0E3"
        case .slate:     return "#1A2332"
        case .night:     return "#0D0D0D"
        case .custom:    return EBookPreferences.shared.customThemeBg
        }
    }

    func cssText(colorScheme: ColorScheme) -> String { cssText }
    var cssText: String {
        switch self {
        case .paper:     return "#1A1A1A"
        case .parchment: return "#3D2B1F"
        case .sepia:     return "#5C4033"
        case .slate:     return "#E8ECF0"
        case .night:     return "#CCCCCC"
        case .custom:    return EBookPreferences.shared.customThemeText
        }
    }

    func cssLink(colorScheme: ColorScheme) -> String { cssLink }
    var cssLink: String {
        switch self {
        case .paper:     return "#7B5EA7"
        case .parchment: return "#8B6914"
        case .sepia:     return "#A0522D"
        case .slate:     return "#6EA4D0"
        case .night:     return "#FF7B2C"
        case .custom:    return "#7B5EA7"
        }
    }

    // Backwards compat shim for callers passing a ColorScheme
    func background(colorScheme: ColorScheme) -> Color { background }
    func foreground(colorScheme: ColorScheme) -> Color { text }
}

// MARK: - Font Family
enum EBookFontFamily: String, CaseIterable, Identifiable {
    case newYork        = "\"New York\", Georgia, serif"
    case georgia        = "Georgia, serif"
    case athelas        = "Athelas, Georgia, serif"
    case literata       = "\"Literata\", Georgia, serif"
    case merriweather   = "\"Merriweather\", Georgia, serif"
    case sourceSerif    = "\"Source Serif 4\", Georgia, serif"
    case helvetica      = "-apple-system, Helvetica, sans-serif"
    case openDyslexic   = "\"OpenDyslexic\", sans-serif"
    case atkinson       = "\"Atkinson Hyperlegible\", sans-serif"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newYork:      return "New York"
        case .georgia:      return "Georgia"
        case .athelas:      return "Athelas"
        case .literata:     return "Literata"
        case .merriweather: return "Merriweather"
        case .sourceSerif:  return "Source Serif 4"
        case .helvetica:    return "System"
        case .openDyslexic: return "OpenDyslexic"
        case .atkinson:     return "Atkinson"
        }
    }

    /// SwiftUI Font for rendering the font name in its own typeface in the picker
    var previewFont: Font {
        switch self {
        case .newYork:      return .custom("NewYorkSmall-Regular", size: 15, relativeTo: .body)
        case .georgia:      return Font(UIFont(name: "Georgia", size: 15) ?? .systemFont(ofSize: 15))
        case .athelas:      return Font(UIFont(name: "Athelas-Regular", size: 15) ?? .systemFont(ofSize: 15))
        case .literata:     return Font(UIFont(name: "Literata-Regular", size: 15) ?? .systemFont(ofSize: 15))
        case .merriweather: return Font(UIFont(name: "Merriweather-Regular", size: 15) ?? .systemFont(ofSize: 15))
        case .sourceSerif:  return Font(UIFont(name: "SourceSerif4-Regular", size: 15) ?? .systemFont(ofSize: 15))
        case .helvetica:    return .system(size: 15)
        case .openDyslexic: return Font(UIFont(name: "OpenDyslexic-Regular", size: 14) ?? .systemFont(ofSize: 14))
        case .atkinson:     return Font(UIFont(name: "AtkinsonHyperlegible-Regular", size: 15) ?? .systemFont(ofSize: 15))
        }
    }
}

// MARK: - Text Alignment
enum EBookTextAlign: String, CaseIterable, Identifiable {
    case justify = "justify"
    case left    = "left"
    var id: String { rawValue }
    var displayName: String { self == .justify ? "Justified" : "Left" }
    var icon: String { self == .justify ? "text.justify" : "text.alignleft" }
}

// MARK: - Pagination Mode
enum EBookPaginationMode: String, CaseIterable, Identifiable {
    case paged      = "Paged"
    case continuous = "Scroll"
    var id: String { rawValue }
    var icon: String { self == .paged ? "book.pages" : "arrow.up.and.down.text.horizontal" }
}
