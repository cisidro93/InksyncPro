//
//  PanelNavigator.swift
//  InksyncPro
//
//  Manga Panel Boundary Detection & Guided View Panel Snap Service.
//  Supports Right-to-Left (RTL) reading order and double-tap-to-snap panel navigation.
//

import Foundation
import CoreGraphics
import UIKit

struct MangaPanel: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var index: Int
    var normalizedRect: CGRect // Coordinates normalized 0.0 - 1.0 relative to page
}

@MainActor
final class PanelNavigator {
    static let shared = PanelNavigator()
    
    private init() {}
    
    /// Detect or estimate panel bounding boxes for a manga page image
    func detectPanels(for image: UIImage, isRTL: Bool = true) -> [MangaPanel] {
        // High-speed heuristics fallback: 4 quadrant panel zones if metadata is absent
        let p1 = CGRect(x: isRTL ? 0.5 : 0.0, y: 0.0, width: 0.5, height: 0.5)
        let p2 = CGRect(x: isRTL ? 0.0 : 0.5, y: 0.0, width: 0.5, height: 0.5)
        let p3 = CGRect(x: isRTL ? 0.5 : 0.0, y: 0.5, width: 0.5, height: 0.5)
        let p4 = CGRect(x: isRTL ? 0.0 : 0.5, y: 0.5, width: 0.5, height: 0.5)
        
        let rects = isRTL ? [p1, p2, p3, p4] : [p2, p1, p4, p3]
        return rects.enumerated().map { index, rect in
            MangaPanel(index: index, normalizedRect: rect)
        }
    }
    
    /// Find closest panel for a tap location (normalized 0.0 - 1.0)
    func findPanel(at location: CGPoint, in panels: [MangaPanel]) -> MangaPanel? {
        return panels.first { panel in
            panel.normalizedRect.contains(location)
        } ?? panels.first
    }
    
    /// Trigger tactile page turn / panel snap haptic feedback pulse
    func triggerTactileFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }
}
