import Foundation

/// Defines which regions of the screen trigger page navigation vs. chrome toggle.
/// Used by PPLReaderView for single-tap routing.
enum TapZoneStyle: String, CaseIterable, Codable {
    case classic = "classic"  // 30% left | 40% center | 30% right
    case kindle  = "kindle"   // 50% left | 50% right  (no chrome zone — every tap turns)
    case wide    = "wide"     // 20% left | 60% center | 20% right
    case lefty   = "lefty"    // 40% left | 20% center | 40% right (thumb-friendly)

    var label: String {
        switch self {
        case .classic: return "Classic (30 / 40 / 30)"
        case .kindle:  return "Kindle   (50 / 50)"
        case .wide:    return "Wide Centre (20 / 60 / 20)"
        case .lefty:   return "Lefty    (40 / 20 / 40)"
        }
    }

    var icon: String {
        switch self {
        case .classic: return "rectangle.split.3x1"
        case .kindle:  return "rectangle.split.2x1"
        case .wide:    return "rectangle.split.3x1.fill"
        case .lefty:   return "hand.point.left"
        }
    }

    /// The left-edge and right-edge boundary as a fraction of screen width.
    /// Tap < leftEdge  → previous page
    /// Tap > rightEdge → next page
    /// Between         → chrome toggle (unless kindle where there is no centre)
    var zones: (leftEdge: CGFloat, rightEdge: CGFloat) {
        switch self {
        case .classic: return (0.30, 0.70)
        case .kindle:  return (0.50, 0.50)
        case .wide:    return (0.20, 0.80)
        case .lefty:   return (0.40, 0.60)
        }
    }
}

/// Page turn visual style for the Metal comic reader.
enum PageTurnStyle: String, CaseIterable, Codable {
    case slide    = "slide"    // Default: live swipe peel reveals next/prev behind current
    case flip3D   = "flip3D"   // 3-D book-page curl using rotation3DEffect
    case instant  = "instant"  // No animation (accessibility / performance mode)

    var label: String {
        switch self {
        case .slide:   return "Slide"
        case .flip3D:  return "Book Flip (3D)"
        case .instant: return "Instant"
        }
    }

    var icon: String {
        switch self {
        case .slide:   return "arrow.left.arrow.right"
        case .flip3D:  return "book"
        case .instant: return "bolt.fill"
        }
    }
}
