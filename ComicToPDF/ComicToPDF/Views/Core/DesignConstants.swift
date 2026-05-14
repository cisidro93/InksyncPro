import SwiftUI

// MARK: - Design Layout Constants
// Single source of truth for spacing, radius, and shadow values.
// Use these instead of magic numbers to keep the UI tactilely consistent.

enum InkRadius {
    /// Standard list/grid card — 14pt continuous
    static let card: CGFloat = 14
    /// Compact badges, tag chips
    static let badge: CGFloat = 6
    /// Small inset cards, media thumbnails
    static let thumbnail: CGFloat = 10
    /// Modal sheets, large floating panels
    static let sheet: CGFloat = 20
}

enum InkShadow {
    static let cardRadius: CGFloat = 8
    static let cardY: CGFloat = 3
    static let cardOpacity: Double = 0.12
    static let overlayRadius: CGFloat = 16
    static let overlayY: CGFloat = 6
    static let overlayOpacity: Double = 0.20
}

enum InkSpacing {
    static let pagePadding: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let rowGap: CGFloat = 12
}

// MARK: - Convenience ViewModifier
extension View {
    /// Standard ink card style: regularMaterial fill, subtle border, consistent radius and shadow.
    func inkCard(radius: CGFloat = InkRadius.card) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(InkShadow.overlayOpacity * 0.6), radius: 8, y: 3)
    }

    /// Ink accent card: gradient fill for hero/featured elements.
    func inkAccentCard(colors: [Color], radius: CGFloat = InkRadius.card) -> some View {
        self
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: colors.first?.opacity(0.35) ?? .clear, radius: 12, y: 4)
    }
}
