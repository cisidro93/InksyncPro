import SwiftUI

/// Reading Color Filters to minimize eye strain and adapt comic/PDF viewing for night reading.
enum ReadingFilter: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case midnight = "Midnight"
    case amber = "Amber"
    case sepia = "Sepia"
    
    var id: String { rawValue }
    var displayName: String { rawValue }
    
    var label: String {
        switch self {
        case .none: return "Standard"
        case .midnight: return "Midnight"
        case .amber: return "Amber Mode"
        case .sepia: return "Sepia"
        }
    }
    
    var icon: String {
        switch self {
        case .none: return "photo"
        case .midnight: return "moon.stars.fill"
        case .amber: return "sun.max.fill"
        case .sepia: return "eye.fill"
        }
    }
}

struct PageColorFilterModifier: ViewModifier {
    let filter: ReadingFilter
    
    func body(content: Content) -> some View {
        switch filter {
        case .none:
            content
        case .midnight:
            // High-performance GPU color inversion with restored hue/skin tones
            content
                .colorInvert()
                .hueRotation(.degrees(180))
        case .amber:
            // Multiplies the page colors by a warm amber/yellow hue to block blue light
            content
                .colorMultiply(Color(red: 1.0, green: 0.86, blue: 0.65))
        case .sepia:
            // Warm classic parchment sepia tone
            content
                .colorMultiply(Color(red: 0.95, green: 0.89, blue: 0.78))
        }
    }
}

extension View {
    /// Applies a reading filter to the page view.
    func readingFilter(_ filter: ReadingFilter) -> some View {
        self.modifier(PageColorFilterModifier(filter: filter))
    }
}
