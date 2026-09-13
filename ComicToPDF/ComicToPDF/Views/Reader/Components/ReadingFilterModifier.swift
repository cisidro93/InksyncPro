import SwiftUI

// MARK: - ReadingFilterModifier
// Applies curated color matrices and adjustments for optimal reading comfort.
struct ReadingFilterModifier: ViewModifier {
    let preset: ReadingFilterPreset
    
    @AppStorage("customContrast") private var customContrast: Double = 1.0
    @AppStorage("customBrightness") private var customBrightness: Double = 0.0
    @AppStorage("customSaturation") private var customSaturation: Double = 1.0

    func body(content: Content) -> some View {
        switch preset {
        case .original:
            content
        case .vintage:
            content
                .contrast(0.9)
                .saturation(0.7)
                .colorMultiply(Color(red: 1.0, green: 0.95, blue: 0.9)) // Warm tone
        case .eink:
            content
                .contrast(1.4)
                .saturation(0.0) // Grayscale
        case .vibrant:
            content
                .contrast(1.1)
                .saturation(1.4)
        case .dark:
            content
                .colorInvert()
                .hueRotation(.degrees(180)) // Invert colors preserving hue
        case .amber:
            content
                .colorMultiply(Color(red: 1.0, green: 0.86, blue: 0.65))
        case .sepia:
            content
                .colorMultiply(Color(red: 0.95, green: 0.89, blue: 0.78))
        case .custom:
            content
                .contrast(customContrast)
                .brightness(customBrightness)
                .saturation(customSaturation)
        }
    }
}

// MARK: - View Extension
extension View {
    func applyFilterPreset(_ preset: ReadingFilterPreset) -> some View {
        modifier(ReadingFilterModifier(preset: preset))
    }

    func applyPDFTheme(
        theme: EBookTheme,
        filter: ReadingFilter = .none,
        filterPresetOverride: ReadingFilterPreset = .original,
        isPencilMode: Bool = false
    ) -> some View {
        modifier(PDFThemeAndFilterModifier(
            theme: theme,
            filter: filter,
            filterPresetOverride: filterPresetOverride,
            isPencilMode: isPencilMode
        ))
    }
}

// MARK: - PDFThemeAndFilterModifier
/// Dynamic color matrix and paper-tint modifier designed specifically for native PDF rendering.
/// Translates EBookPreferences themes (Paper, Parchment, Sepia, Slate, Night, OLED, Custom)
/// and eye-comfort filters (Amber, Sepia, Midnight) directly onto vector and scanned PDF pages.
struct PDFThemeAndFilterModifier: ViewModifier {
    let theme: EBookTheme
    let filter: ReadingFilter
    let filterPresetOverride: ReadingFilterPreset
    let isPencilMode: Bool

    @AppStorage("customContrast") private var customContrast: Double = 1.0
    @AppStorage("customBrightness") private var customBrightness: Double = 0.0
    @AppStorage("customSaturation") private var customSaturation: Double = 1.0

    func body(content: Content) -> some View {
        if filterPresetOverride != .original {
            // Priority 1: User explicitly engaged Quick Filter HUD preset
            content.modifier(ReadingFilterModifier(preset: filterPresetOverride))
        } else {
            // Priority 2: EBookPreferences Engine Theme & Eye Comfort Filter
            applyEngineThemeAndFilter(to: content)
        }
    }

    @ViewBuilder
    private func applyEngineThemeAndFilter(to content: Content) -> some View {
        // Step A: Apply Base Reading Theme
        let themedContent = applyBaseTheme(to: content)

        // Step B: Apply Eye Comfort Filter Layer
        switch filter {
        case .none:
            themedContent
        case .amber:
            themedContent
                .colorMultiply(Color(red: 1.0, green: 0.86, blue: 0.65))
        case .sepia:
            // If theme is not already sepia or parchment, apply warm sepia multiplier
            if theme != .sepia && theme != .parchment {
                themedContent
                    .colorMultiply(Color(red: 0.95, green: 0.89, blue: 0.78))
            } else {
                themedContent
            }
        case .midnight:
            themedContent
                .colorMultiply(Color(red: 0.85, green: 0.88, blue: 0.95))
                .brightness(-0.06)
        }
    }

    @ViewBuilder
    private func applyBaseTheme(to content: Content) -> some View {
        switch theme {
        case .paper:
            content

        case .parchment:
            // High-grade warm book paper (#FBF7EF) - non-destructive
            content
                .colorMultiply(Color(hex: "#FBF7EF"))

        case .sepia:
            // Calming warm sepia reading tone (#F8F0E3) - non-destructive
            content
                .colorMultiply(Color(hex: "#F8F0E3"))

        case .slate:
            // Cool calming slate paper tone (#E2EAF2) - non-destructive, soothing on the eyes
            content
                .colorMultiply(Color(hex: "#E2EAF2"))

        case .night:
            // Comfortable dark mode - persistent across reading and markup mode
            content
                .colorInvert()
                .hueRotation(.degrees(180))
                .contrast(0.95)
                .brightness(-0.04)

        case .oled:
            // Pure black OLED mode - persistent across reading and markup mode
            content
                .colorInvert()
                .hueRotation(.degrees(180))
                .contrast(1.1)

        case .custom:
            let bgHex = EBookPreferences.shared.customThemeBg
            let isDarkCustom = theme.isDark
            if isDarkCustom {
                content
                    .colorInvert()
                    .hueRotation(.degrees(180))
                    .colorMultiply(Color(hex: bgHex))
            } else {
                content
                    .colorMultiply(Color(hex: bgHex))
            }
        }
    }
}
