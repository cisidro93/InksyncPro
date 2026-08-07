//
//  EPUBThemeInjectionService.swift
//  InksyncPro
//
//  CSS Theme & Accessibility Typography Injection Service for EPUB Reading Engine.
//  Enforces true OLED Pure-Black (#000000) themes, Sepia tones, and OpenDyslexic / Lexend fonts.
//

import Foundation
import UIKit

@MainActor
final class EPUBThemeInjectionService {
    static let shared = EPUBThemeInjectionService()
    
    private init() {}
    
    enum ThemeMode: String, CaseIterable, Codable {
        case light = "light"
        case sepia = "sepia"
        case dark = "dark"
        case oled = "oled"
        
        var backgroundColorHex: String {
            switch self {
            case .light: return "#FFFFFF"
            case .sepia: return "#FBF0D9"
            case .dark: return "#1C1C1E"
            case .oled: return "#000000"
            }
        }
        
        var textColorHex: String {
            switch self {
            case .light: return "#111111"
            case .sepia: return "#5F4B32"
            case .dark: return "#E5E5EA"
            case .oled: return "#FFFFFF"
            }
        }
    }
    
    enum TypographyFont: String, CaseIterable, Codable {
        case system = "System"
        case inter = "Inter"
        case openDyslexic = "OpenDyslexic"
        case lexend = "Lexend"
        
        var fontFamilyCSS: String {
            switch self {
            case .system: return "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
            case .inter: return "'Inter', -apple-system, sans-serif"
            case .openDyslexic: return "'OpenDyslexic', sans-serif"
            case .lexend: return "'Lexend', sans-serif"
            }
        }
    }
    
    /// Generate complete CSS block for EPUB WKWebView rendering
    func generateCSS(theme: ThemeMode, font: TypographyFont, fontSize: CGFloat, margin: CGFloat) -> String {
        return """
        body, html {
            background-color: \(theme.backgroundColorHex) !important;
            color: \(theme.textColorHex) !important;
            font-family: \(font.fontFamilyCSS) !important;
            font-size: \(fontSize)px !important;
            line-height: 1.6 !important;
            margin: 0 !important;
            padding: 0 !important;
            -webkit-text-size-adjust: 100% !important;
        }
        
        p, div, span, li, a, h1, h2, h3, h4, h5, h6 {
            color: \(theme.textColorHex) !important;
            font-family: \(font.fontFamilyCSS) !important;
        }
        
        img {
            max-width: 100% !important;
            height: auto !important;
            display: block !important;
            margin: 12px auto !important;
            border-radius: 4px !important;
        }
        
        ::selection {
            background-color: rgba(255, 215, 0, 0.4) !important;
        }
        """
    }
}
