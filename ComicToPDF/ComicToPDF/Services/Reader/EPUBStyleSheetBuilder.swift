import Foundation
import UIKit

// MARK: - EPUB Typography Options

enum EPUBTextAlignment: String, CaseIterable, Codable, Sendable {
    case left      = "left"
    case justified = "justify"
    case center    = "center"
    
    var cssValue: String { rawValue }
}

struct CustomFontDescriptor: Identifiable, Sendable, Hashable {
    let id: String
    let familyName: String
    let fileURL: URL
    
    init(familyName: String, fileURL: URL) {
        self.id = familyName
        self.familyName = familyName
        self.fileURL = fileURL
    }
}

// MARK: - EPUB Style Sheet Builder

/// Comprehensive CSS and typography generator for the EPUB WKWebView reading engine.
/// Injects dynamic `@font-face` declarations from `Documents/Fonts/`, text justification,
/// automatic language-aware hyphenation, and TTS active sentence highlighting rules.
final class EPUBStyleSheetBuilder: Sendable {
    
    static let shared = EPUBStyleSheetBuilder()
    
    init() {}
    
    // MARK: - Custom Font Discovery
    
    /// Discovers user-installed TrueType / OpenType fonts in `Documents/Fonts/`.
    func discoverCustomFonts() -> [CustomFontDescriptor] {
        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let fontsDirectory = docsURL.appendingPathComponent("Fonts", isDirectory: true)
        
        guard (try? fontsDirectory.checkResourceIsReachable()) == true,
              let contents = try? fileManager.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var fonts: [CustomFontDescriptor] = []
        for file in contents {
            let ext = file.pathExtension.lowercased()
            if ext == "ttf" || ext == "otf" {
                let name = file.deletingPathExtension().lastPathComponent
                fonts.append(CustomFontDescriptor(familyName: name, fileURL: file))
            }
        }
        return fonts
    }
    
    // MARK: - CSS Generation
    
    /// Generates complete CSS string with font declarations, layout alignment, hyphenation, and themes.
    func generateCSS(
        theme: EPUBThemeInjectionService.ThemeMode,
        font: EPUBThemeInjectionService.TypographyFont,
        customFontFamily: String? = nil,
        fontSize: CGFloat,
        lineSpacingMultiplier: Double = 1.5,
        alignment: EPUBTextAlignment = .left,
        isHyphenationEnabled: Bool = true,
        horizontalMargin: CGFloat = 24
    ) -> String {
        var fontFaceRules = ""
        let customFonts = discoverCustomFonts()
        
        for custom in customFonts {
            fontFaceRules += """
            @font-face {
                font-family: '\(custom.familyName)';
                src: url('\(custom.fileURL.absoluteString)');
            }
            """
        }
        
        let effectiveFontFamily: String
        if let customName = customFontFamily, !customName.isEmpty {
            effectiveFontFamily = "'\(customName)', \(font.fontFamilyCSS)"
        } else {
            effectiveFontFamily = font.fontFamilyCSS
        }
        
        let hyphenationCSS = isHyphenationEnabled ? """
            -webkit-hyphens: auto !important;
            hyphens: auto !important;
            -webkit-hyphenate-limit-lines: 2 !important;
        """ : """
            -webkit-hyphens: manual !important;
            hyphens: manual !important;
        """
        
        return """
        \(fontFaceRules)
        
        body, html {
            background-color: \(theme.backgroundColorHex) !important;
            color: \(theme.textColorHex) !important;
            font-family: \(effectiveFontFamily) !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineSpacingMultiplier) !important;
            text-align: \(alignment.cssValue) !important;
            \(hyphenationCSS)
            margin: 0 !important;
            padding: 0 \(horizontalMargin)px !important;
            -webkit-text-size-adjust: 100% !important;
            word-break: break-word !important;
        }
        
        body * {
            font-family: \(effectiveFontFamily) !important;
        }
        
        p, div, span, li, a, blockquote, em, strong, b, i, table, td, th, dt, dd, article, section {
            color: \(theme.textColorHex) !important;
            font-family: \(effectiveFontFamily) !important;
            text-align: \(alignment.cssValue) !important;
            line-height: \(lineSpacingMultiplier) !important;
            \(hyphenationCSS)
        }
        
        h1, h2, h3, h4, h5, h6 {
            color: \(theme.textColorHex) !important;
            font-family: \(effectiveFontFamily) !important;
            text-align: \(alignment.cssValue) !important;
            line-height: 1.25 !important;
            margin-top: 1.2em !important;
            margin-bottom: 0.6em !important;
            \(hyphenationCSS)
        }
        
        img {
            max-width: 100% !important;
            height: auto !important;
            display: block !important;
            margin: 16px auto !important;
            border-radius: 6px !important;
        }
        
        ::selection {
            background-color: rgba(255, 214, 10, 0.4) !important;
        }
        
        /* On-Device TTS Active Sentence Highlighting */
        mark.inksync-tts-active {
            background-color: rgba(94, 92, 230, 0.35) !important;
            color: inherit !important;
            border-radius: 4px !important;
            padding: 2px 4px !important;
            transition: background-color 0.2s ease-in-out !important;
        }
        """
    }
}
