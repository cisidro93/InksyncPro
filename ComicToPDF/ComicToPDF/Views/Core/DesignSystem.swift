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
    static let inkOrange = Color(hex: "#ff9f0a")
    static let inkGreen  = Color(hex: "#2dd4a0")
    static let inkRed    = Color(hex: "#ff4d6d")


    // MARK: - Semantic Role Aliases
    /// Navigation, progress bars, active tab indicator — the "engine running" colour
    static let inkAccentNavigation  = inkAmber
    /// Research, annotation, writing, Zettelkasten — the "mind" colour
    static let inkAccentKnowledge   = inkViolet
    /// Convenient short aliases
    static let inkText              = inkTextPrimary
    static let inkSecondary         = inkTextSecondary
    static let inkTertiary          = inkTextTertiary
    static let inkYellow            = inkAmber
    static let inkPurple            = inkViolet

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
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(g * 255))
    }
}

// MARK: - Reusable Inksync UI Primitives

/// Signature uppercase tracked section header used across all Inksync Pro menus and HUDs.
/// Differentiates iPhone (11pt, 0.8 tracking) vs iPad (13pt, 1.0 tracking) for native ergonomics.
struct InkSectionHeader: View {
    let title: String
    
    init(_ title: String) {
        self.title = title
    }
    
    var body: some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        HStack {
            Text(title.uppercased())
                .font(.system(size: isPad ? 13 : 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.inkTextSecondary)
                .tracking(isPad ? 1.0 : 0.8)
            Spacer()
        }
    }
}

/// Standardized translucent top drag handle capsule for Inksync Pro modal sheets.
/// Features adaptive contrast for Light & Dark mode and tailored width for iPhone vs iPad.
struct InkSheetDragPill: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        Capsule()
            .fill(colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.18))
            .frame(width: isPad ? 48 : 36, height: isPad ? 5 : 4)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }
}

/// Adaptive specular border modifier that provides clean highlight gradients in both Light and Dark mode.
struct AdaptiveSpecularBorderModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat
    var lineWidth: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.18), Color.white.opacity(0.04)]
                            : [Color.black.opacity(0.09), Color.black.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: lineWidth
                )
        )
    }
}

extension View {
    /// Applies the signature Inksync Pro specular highlight stroke border to cards and modal containers.
    /// Automatically adapts highlights for both Light and Dark modes.
    func inkSpecularBorder(cornerRadius: CGFloat = 14, lineWidth: CGFloat = 0.8) -> some View {
        modifier(AdaptiveSpecularBorderModifier(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

// Note: UIColor(hex:) is defined in BookReaderEngine.swift and is available app-wide.
// The adaptive dynamic-provider closures in the extension above call that existing init.
