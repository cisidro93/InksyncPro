import SwiftUI

extension Color {
    // MARK: - Adaptive Semantic Tokens
    // All colors respond to system light/dark mode automatically.
    // Dark values match the original design; light values provide clean white-surface equivalents.

    /// Page/canvas background — near-black in dark, pure system background in light
    static let inkBackground = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#09090f") ?? UIColor.systemBackground
            : UIColor.systemBackground
    })

    /// Card/surface fill — dark surface in dark, secondary grouped background in light
    static let inkSurface = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#111118") ?? UIColor.secondarySystemGroupedBackground
            : UIColor.secondarySystemGroupedBackground
    })

    /// Elevated surface — slightly lighter in dark, tertiary in light
    static let inkSurfaceRaised = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#1a1a28") ?? UIColor.tertiarySystemGroupedBackground
            : UIColor.tertiarySystemGroupedBackground
    })

    /// Subtle separator
    static let inkBorderSubtle = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#1e1e30") ?? UIColor.separator.withAlphaComponent(0.2)
            : UIColor.separator.withAlphaComponent(0.2)
    })

    /// Visible separator
    static let inkBorderVisible = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#2a2a45") ?? UIColor.separator
            : UIColor.separator
    })

    /// Primary text — almost-white in dark, label in light
    static let inkTextPrimary = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#e8e8f5") ?? UIColor.label
            : UIColor.label
    })

    /// Secondary text — muted purple-grey in dark, secondaryLabel in light
    static let inkTextSecondary = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#7070a0") ?? UIColor.secondaryLabel
            : UIColor.secondaryLabel
    })

    /// Tertiary text — very muted in dark, tertiaryLabel in light
    static let inkTextTertiary = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "#40405a") ?? UIColor.tertiaryLabel
            : UIColor.tertiaryLabel
    })

    // MARK: - Accent Colors (unchanged — vibrant in both modes)
    static let inkBlue   = Color(hex: "#3d6fff")
    static let inkViolet = Color(hex: "#8b5cf6")
    static let inkAmber  = Color(hex: "#f5a623")
    static let inkGreen  = Color(hex: "#2dd4a0")
    static let inkRed    = Color(hex: "#ff4d6d")

    // MARK: - Hex Initializers
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    
    func toHex() -> String? {
        // Safe conversion utilizing UIKit resolving underlying traits dynamically
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}
// Note: UIColor(hex:) is defined in BookReaderEngine.swift and is available app-wide.
// The adaptive dynamic-provider closures in the extension above call that existing init.
