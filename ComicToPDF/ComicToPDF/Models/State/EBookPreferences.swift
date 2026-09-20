import SwiftUI
import UIKit

// MARK: - Core Preference Data Engine
@MainActor
class EBookPreferences: ObservableObject {
    static let shared = EBookPreferences()

    // MARK: - Theme
    var themeRaw: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "ebook_theme") {
                return saved
            }
            // Dynamic default: Match system appearance if user hasn't customized it yet
            if UITraitCollection.current.userInterfaceStyle == .dark {
                return EBookTheme.night.rawValue
            } else {
                return EBookTheme.paper.rawValue
            }
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ebook_theme")
            objectWillChange.send()
        }
    }

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
    @AppStorage("ebook_isBionicReadingEnabled") var isBionicReadingEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_fontSize")       var fontSize: Double    = 18
    @AppStorage("ebook_lineHeight")     var lineHeight: Double  = 1.6
    @AppStorage("ebook_letterSpacing")  var letterSpacing: Double = 0.0   // em
    @AppStorage("ebook_wordSpacing")    var wordSpacing: Double   = 0.0   // em
    @AppStorage("ebook_textAlign")      var textAlign: String   = EBookTextAlign.justify.rawValue
    @AppStorage("ebook_hyphenation")    var hyphenation: Bool   = true
    @AppStorage("ebook_isBoldTextEnabled") var isBoldTextEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }

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
    @AppStorage("ebook_columns")        var columnCount: Int       = 0 // 0 = Auto, 1 = Single, 2 = Double

    // MARK: - Reader Features
    @AppStorage("ebook_readingRuler")   var showReadingRuler: Bool  = false
    @AppStorage("ebook_rulerYPosition") var rulerYPosition: Double  = 0.4   // fraction of screen height
    @AppStorage("ebook_autoScroll")     var autoScroll: Bool        = false
    @AppStorage("ebook_autoScrollSpeed") var autoScrollSpeed: Double = 1.0  // multiplier
    @AppStorage("ebook_showReadingSpeedStats") var showReadingSpeedStats: Bool = false

    // MARK: - Display Idle Timer / Always-On
    @AppStorage("ebook_keepScreenAwakeWhileReading") var keepScreenAwakeWhileReading: Bool = true {
        didSet {
            objectWillChange.send()
            ReaderIdleTimerManager.shared.reassertKeepAwake()
        }
    }
    @AppStorage("ebook_readingSpeedWPM") var readingSpeedWPM: Double = 250.0
    @AppStorage("ebook_showClockHeader") var showClockHeader: Bool = true
    @AppStorage("ebook_showBatteryPercentage") var showBatteryPercentage: Bool = true
    @AppStorage("ebook_fullBleedSpreads") var fullBleedSpreads: Bool = true
    @AppStorage("ebook_linkCoverAsSpread") var linkCoverAsSpread: Bool = false
    @AppStorage("volumeButtonsTurnPages") var volumeButtonsTurnPages: Bool = true {
        didSet { objectWillChange.send() }
    }

    // MARK: - Archive & Streaming Settings
    @AppStorage("useZeroCopyStreaming") var useZeroCopyStreaming: Bool = true {
        didSet { objectWillChange.send() }
    }

    // MARK: - PDF Settings
    @AppStorage("pdf_reflowMode")       var pdfReflowMode: Bool     = false {
        didSet { objectWillChange.send() }
    }

    // Progress display mode (cycles on tap: 0=page, 1=remaining, 2=timeLeft, 3=WPM, 4=hidden)
    @AppStorage("ebook_progressMode")   var progressMode: Int = 0

    // MARK: - Customizable Tap Zones Layout
    @AppStorage("tapZoneStyle") var tapZoneStyleRaw: String = TapZoneStyle.classic.rawValue
    var tapZoneStyle: TapZoneStyle {
        get { TapZoneStyle(rawValue: tapZoneStyleRaw) ?? .classic }
        set { 
            tapZoneStyleRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    @AppStorage("ebook_pageTurnStyle") var pageTurnStyleRaw: String = PageTurnStyle.flip3D.rawValue
    var pageTurnStyle: PageTurnStyle {
        get { PageTurnStyle(rawValue: pageTurnStyleRaw) ?? .flip3D }
        set { 
            pageTurnStyleRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    // MARK: - Reading Color Filters (Midnight, Amber, Sepia)
    @AppStorage("ebook_readingFilter") var readingFilterRaw: String = ReadingFilter.none.rawValue
    var readingFilter: ReadingFilter {
        get { ReadingFilter(rawValue: readingFilterRaw) ?? .none }
        set { readingFilterRaw = newValue.rawValue }
    }

    // MARK: - PDF Specific Layouts
    @AppStorage("pdf_dualPage") var pdfDualPage: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_fitToWidth") var pdfFitToWidth: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_rtlDirection") var pdfRTL: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("autoLandscapeDualPage") var autoLandscapeDualPage: Bool = true {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_glideHighlighting") var glideHighlighting: Bool = true {
        didSet { objectWillChange.send() }
    }

    // MARK: - Auto-Theme Scheduling
    @AppStorage("ebook_autoThemeEnabled")   var isAutoThemeEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_dayThemeRaw")         var dayThemeRaw: String       = EBookTheme.paper.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_nightThemeRaw")       var nightThemeRaw: String     = EBookTheme.night.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_autoThemeStartHour")  var autoThemeStartHour: Int   = 20 { // 8:00 PM
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_autoThemeEndHour")    var autoThemeEndHour: Int     = 7 {  // 7:00 AM
        didSet { objectWillChange.send() }
    }

    // MARK: - PDF & Comic White-Margin Auto-Crop Sensitivity
    @AppStorage("ebook_isSmartCropEnabled")   var isSmartCropEnabled: Bool   = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_autoCropSensitivity")  var autoCropSensitivity: Double = 0.10 { // 10% threshold (0.0 to 0.20)
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_autoContrastLevel")    var autoContrastLevel: Double   = 1.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_saturationLevel")      var saturationLevel: Double     = 1.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_warmthLevel")          var warmthLevel: Double         = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_defaultCropModeRaw")   var defaultCropModeRaw: String = "none" {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_defaultCropTop")       var defaultCropTop: Double     = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_defaultCropBottom")    var defaultCropBottom: Double  = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_defaultCropLeft")      var defaultCropLeft: Double    = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_defaultCropRight")     var defaultCropRight: Double   = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_isOddEvenCropEnabled") var isOddEvenCropEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_evenPageGutterOffset") var evenPageGutterOffset: Double = 0.02 {
        didSet { objectWillChange.send() }
    }

    // MARK: - Comic / Manga Screen Fit Mode (iPhone Full-Bleed Scaling)
    @AppStorage("comic_pageFitMode") var comicPageFitModeRaw: String = ComicPageFitMode.fitWidth.rawValue {
        didSet { objectWillChange.send() }
    }
    var comicPageFitMode: ComicPageFitMode {
        get { ComicPageFitMode(rawValue: comicPageFitModeRaw) ?? .fitWidth }
        set {
            comicPageFitModeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    // MARK: - Comic & PDF Guided View Panel Inspection Style (Smart Tiers)
    @AppStorage("comic_panelInspectionStyle") var panelInspectionStyleRaw: String = PanelInspectionStyle.smartStrides.rawValue {
        didSet { objectWillChange.send() }
    }
    var panelInspectionStyle: PanelInspectionStyle {
        get { .smartStrides }
        set {
            panelInspectionStyleRaw = PanelInspectionStyle.smartStrides.rawValue
            objectWillChange.send()
        }
    }

    // PDF Smart Tiers Enabled Flag
    @AppStorage("pdf_smartTiersActive") var isPDFSmartTiersActive: Bool = false {
        didSet { objectWillChange.send() }
    }

    // MARK: - PDF Smart Tiers Configuration & Limits
    @AppStorage("pdf_smartTierPreset") var pdfSmartTierPresetRaw: String = PDFTierLayoutPreset.twoColumn.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierColumnCount") var pdfSmartTierColumnCount: Int = 2 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierTiersPerColumn") var pdfSmartTierTiersPerColumn: Int = 3 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierColumnSplitRatio") var pdfSmartTierColumnSplitRatio: Double = 0.50 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierVerticalOverlap") var pdfSmartTierVerticalOverlap: Double = 0.15 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierTopTrim") var pdfSmartTierTopTrim: Double = 0.04 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierBottomTrim") var pdfSmartTierBottomTrim: Double = 0.04 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierLeftTrim") var pdfSmartTierLeftTrim: Double = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierRightTrim") var pdfSmartTierRightTrim: Double = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_smartTierFlowOrder") var pdfSmartTierFlowOrderRaw: String = PDFReadingFlowOrder.columnFirst.rawValue {
        didSet { objectWillChange.send() }
    }

    var pdfTierConfiguration: PDFTierGuideConfiguration {
        get {
            PDFTierGuideConfiguration(
                preset: PDFTierLayoutPreset(rawValue: pdfSmartTierPresetRaw) ?? .twoColumn,
                columnCount: pdfSmartTierColumnCount,
                tiersPerColumn: pdfSmartTierTiersPerColumn,
                columnSplitRatio: CGFloat(pdfSmartTierColumnSplitRatio),
                verticalOverlap: CGFloat(pdfSmartTierVerticalOverlap),
                topMarginTrim: CGFloat(pdfSmartTierTopTrim),
                bottomMarginTrim: CGFloat(pdfSmartTierBottomTrim),
                leftMarginTrim: CGFloat(pdfSmartTierLeftTrim),
                rightMarginTrim: CGFloat(pdfSmartTierRightTrim),
                flowOrder: PDFReadingFlowOrder(rawValue: pdfSmartTierFlowOrderRaw) ?? .columnFirst
            )
        }
        set {
            pdfSmartTierPresetRaw = newValue.preset.rawValue
            pdfSmartTierColumnCount = newValue.columnCount
            pdfSmartTierTiersPerColumn = newValue.tiersPerColumn
            pdfSmartTierColumnSplitRatio = Double(newValue.columnSplitRatio)
            pdfSmartTierVerticalOverlap = Double(newValue.verticalOverlap)
            pdfSmartTierTopTrim = Double(newValue.topMarginTrim)
            pdfSmartTierBottomTrim = Double(newValue.bottomMarginTrim)
            pdfSmartTierLeftTrim = Double(newValue.leftMarginTrim)
            pdfSmartTierRightTrim = Double(newValue.rightMarginTrim)
            pdfSmartTierFlowOrderRaw = newValue.flowOrder.rawValue
            objectWillChange.send()
        }
    }

    // MARK: - Comic Smart Tiers Quick Adjust Configuration
    @AppStorage("comic_smartTierPreset") var comicSmartTierPresetRaw: String = ComicTierLayoutPreset.threeTier.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierCount") var comicSmartTierCount: Int = 3 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierColumnCount") var comicSmartTierColumnCount: Int = 1 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierOverlap") var comicSmartTierOverlap: Double = 0.15 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierColumnSplitRatio") var comicSmartTierColumnSplitRatio: Double = 0.50 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierTopMarginTrim") var comicSmartTierTopMarginTrim: Double = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierBottomMarginTrim") var comicSmartTierBottomMarginTrim: Double = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierLeftTrim") var comicSmartTierLeftTrim: Double = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierRightTrim") var comicSmartTierRightTrim: Double = 0.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("comic_smartTierFlowOrder") var comicSmartTierFlowOrderRaw: String = ComicReadingFlowOrder.mangaRTL.rawValue {
        didSet { objectWillChange.send() }
    }

    var comicTierConfiguration: ComicTierGuideConfiguration {
        get {
            ComicTierGuideConfiguration(
                preset: ComicTierLayoutPreset(rawValue: comicSmartTierPresetRaw) ?? .threeTier,
                tierCount: comicSmartTierCount,
                columnCount: comicSmartTierColumnCount,
                overlap: comicSmartTierOverlap,
                columnSplitRatio: comicSmartTierColumnSplitRatio,
                topMarginTrim: comicSmartTierTopMarginTrim,
                bottomMarginTrim: comicSmartTierBottomMarginTrim,
                leftMarginTrim: comicSmartTierLeftTrim,
                rightMarginTrim: comicSmartTierRightTrim,
                flowOrder: ComicReadingFlowOrder(rawValue: comicSmartTierFlowOrderRaw) ?? .mangaRTL
            )
        }
        set {
            comicSmartTierPresetRaw = newValue.preset.rawValue
            comicSmartTierCount = newValue.tierCount
            comicSmartTierColumnCount = newValue.columnCount
            comicSmartTierOverlap = newValue.overlap
            comicSmartTierColumnSplitRatio = newValue.columnSplitRatio
            comicSmartTierTopMarginTrim = newValue.topMarginTrim
            comicSmartTierBottomMarginTrim = newValue.bottomMarginTrim
            comicSmartTierLeftTrim = newValue.leftMarginTrim
            comicSmartTierRightTrim = newValue.rightMarginTrim
            comicSmartTierFlowOrderRaw = newValue.flowOrder.rawValue
            objectWillChange.send()
        }
    }

    var defaultCodableCropInsets: CodableCropInsets {
        CodableCropInsets(
            top: defaultCropTop,
            bottom: defaultCropBottom,
            left: defaultCropLeft,
            right: defaultCropRight,
            modeRaw: "custom"
        )
    }

    // MARK: - Academic Article / Column Mode
    @AppStorage("pdf_isArticleMode")          var isArticleMode: Bool        = false {
        didSet { objectWillChange.send() }
    }

    // MARK: - Granular 4-Edge EPUB Margins
    @AppStorage("ebook_textMarginTop")        var textMarginTop: Double      = 24.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_textMarginBottom")     var textMarginBottom: Double   = 24.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_textMarginLeft")       var textMarginLeft: Double     = 24.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_textMarginRight")      var textMarginRight: Double    = 24.0 {
        didSet { objectWillChange.send() }
    }

    // MARK: - Panels-Style Persistent Lock Zoom
    @AppStorage("pdf_isZoomLocked")           var isZoomLocked: Bool         = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("pdf_lockedZoomScale")        var lockedZoomScale: Double    = 1.0 {
        didSet { objectWillChange.send() }
    }

    // MARK: - KyBook 3-Style RSVP Speed Reading
    @AppStorage("ebook_rsvpSpeedWPM")         var rsvpSpeedWPM: Double       = 350.0
    @AppStorage("ebook_rsvpChunkSize")        var rsvpChunkSize: Int         = 1

    // MARK: - Active theme helpers
    var activeTheme: EBookTheme {
        if isAutoThemeEnabled {
            let hour = Calendar.current.component(.hour, from: Date())
            let isNight = autoThemeStartHour > autoThemeEndHour
                ? (hour >= autoThemeStartHour || hour < autoThemeEndHour)
                : (hour >= autoThemeStartHour && hour < autoThemeEndHour)
            let targetRaw = isNight ? nightThemeRaw : dayThemeRaw
            return EBookTheme(rawValue: targetRaw) ?? .paper
        } else {
            return EBookTheme(rawValue: themeRaw) ?? .paper
        }
    }

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
        if let bold = profile.isBoldTextEnabled { isBoldTextEnabled = bold }
        textMargin      = profile.textMargin
        paragraphIndent = profile.paragraphIndent
        paragraphSpacing = profile.paragraphSpacing
        columnCount     = profile.columnCount ?? 0
    }

    /// Save all current typography settings for a specific book.
    func lockTypographyForBook(_ bookID: String) {
        var profiles = bookTypographyProfiles
        profiles[bookID] = BookTypographyProfile(
            fontFamily:        fontFamily,
            fontSize:          fontSize,
            lineHeight:        lineHeight,
            letterSpacing:     letterSpacing,
            wordSpacing:       wordSpacing,
            textAlign:         textAlign,
            hyphenation:       hyphenation,
            isBoldTextEnabled: isBoldTextEnabled,
            textMargin:        textMargin,
            paragraphIndent:   paragraphIndent,
            paragraphSpacing:  paragraphSpacing,
            columnCount:       columnCount
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

    // MARK: - Apple Pencil & Native Annotation Settings
    @AppStorage("ebook_applePencilAutoDraw") var applePencilAutoDraw: Bool = true {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_applePencilDefaultTool") var applePencilDefaultTool: String = "pen" {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_applePencilDoubleTapAction") var applePencilDoubleTapAction: String = "switchEraser" {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ebook_applePencilHoverEnabled") var applePencilHoverEnabled: Bool = true {
        didSet { objectWillChange.send() }
    }

    // MARK: - Highlight Color Preference
    @AppStorage("reader_defaultHighlightColor") var defaultHighlightColorRaw: String = "#FFD600" {
        didSet { objectWillChange.send() }
    }
    var defaultHighlightColor: PDFHighlightColor {
        get { PDFHighlightColor(rawValue: defaultHighlightColorRaw) ?? .yellow }
        set { defaultHighlightColorRaw = newValue.rawValue }
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
    var isBoldTextEnabled: Bool?
    var textMargin: Double
    var paragraphIndent: Double
    var paragraphSpacing: Double
    var columnCount: Int?
}

// MARK: - Theme Engine
@MainActor
enum EBookTheme: String, CaseIterable, Identifiable {
    case paper     = "Paper"
    case parchment = "Parchment"
    case sepia     = "Sepia"
    case slate     = "Slate"
    case night     = "Night"
    case oled      = "OLED"
    case custom    = "Custom"

    nonisolated var id: String { rawValue }

    var displayName: String { rawValue }

    var background: Color {
        switch self {
        case .paper:     return Color(hex: "#FFFFFF")
        case .parchment: return Color(hex: "#FBF7EF")
        case .sepia:     return Color(hex: "#F8F0E3")
        case .slate:     return Color(hex: "#1A2332")
        case .night:     return Color(hex: "#0D0D0D")
        case .oled:      return Color(hex: "#000000")
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
        case .oled:      return Color(hex: "#CBD5E1")
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
        case .oled:      return Color(hex: "#A855F7")
        case .custom:    return Color(hex: "#7B5EA7")
        }
    }

    var isDark: Bool {
        switch self {
        case .slate, .night, .oled: return true
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
        case .oled:      return "#000000"
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
        case .oled:      return "#CBD5E1"
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
        case .oled:      return "#A855F7"
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
    case sfMono         = "\"SF Mono\", ui-monospace, Menlo, Monaco, Courier, monospace"

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
        case .sfMono:       return "Monospace"
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
        case .sfMono:       return .system(size: 14, design: .monospaced)
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

// MARK: - Reading Progress Footer Mode
enum ReadingProgressMode: Int, CaseIterable, Identifiable, Sendable {
    case pageAndChapter = 0
    case pagesRemaining = 1
    case timeRemaining  = 2
    case readingPaceWPM = 3
    case hidden         = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .pageAndChapter: return "Page & Chapter"
        case .pagesRemaining: return "Pages Left"
        case .timeRemaining:  return "Time Left"
        case .readingPaceWPM: return "Pace (WPM)"
        case .hidden:         return "Hidden"
        }
    }

    var displayName: String { title }

    var shortTitle: String {
        switch self {
        case .pageAndChapter: return "Page"
        case .pagesRemaining: return "Left"
        case .timeRemaining:  return "Time"
        case .readingPaceWPM: return "WPM"
        case .hidden:         return "Off"
        }
    }
}

// MARK: - Comic Page Fit Mode
enum ComicPageFitMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fitWidth   = "fitWidth"   // Scales comic page to 100% of screen width
    case fillScreen = "fillScreen" // True edge-to-edge full bleed filling 100% of display
    case fitPage    = "fitPage"    // Full page aspect fit (classic letterboxed overview)
    case smartFit   = "smartFit"   // Auto-crops margins & fits artwork to maximize screen real estate
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .fitWidth:   return "Fit Width"
        case .fillScreen: return "Fill Screen"
        case .fitPage:    return "Fit Page"
        case .smartFit:   return "Smart Fit"
        }
    }
    
    var subtitle: String {
        switch self {
        case .fitWidth:   return "Matches screen width edge-to-edge"
        case .fillScreen: return "Full bleed screen coverage without letterboxing"
        case .fitPage:    return "Full page overview with letterboxing"
        case .smartFit:   return "Auto-crops borders to maximize artwork size"
        }
    }
    
    var icon: String {
        switch self {
        case .fitWidth:   return "arrow.left.and.right.square"
        case .fillScreen: return "arrow.up.left.and.arrow.down.right.square"
        case .fitPage:    return "aspectratio"
        case .smartFit:   return "sparkles.rectangle.stack"
        }
    }
}

// MARK: - Guided View Panel Inspection Style
enum PanelInspectionStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case smartStrides = "smartStrides" // Smart Tiers (Top / Mid / Bottom half & tier viewer)

    var id: String { rawValue }

    var title: String {
        return "Smart Tiers"
    }

    var subtitle: String {
        return "Top, middle, & bottom page gutter strides with continuous flow"
    }

    var icon: String {
        return "rectangle.split.3x1"
    }
}
