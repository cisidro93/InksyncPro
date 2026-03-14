import Foundation
import UIKit
import PencilKit

/// Core Data Structure for an Editable Inksync Planner Project (*.inksycPlanner)
struct PlannerProject: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var creationDate: Date = Date()
    var isFavorite: Bool = false
    var targetDevice: TargetDeviceProfile = .original
    var coverThumbnailData: Data? = nil // Compressed PNG for Vault Gallery
    
    var pages: [PlannerPage] = []
    
    var fileExtension: String { "inksycPlanner" }
}

struct PlannerPage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String? = nil
    
    /// Optional rasterized PDF or Template Background
    var backgroundImageData: Data? = nil
    
    /// Serialized PencilKit Strokes (PKDrawing.dataRepresentation)
    var drawingData: Data = Data()
    
    /// Vector Objects and Link Zones overlaying the page
    var elements: [PlannerElement] = []
}

struct PlannerElement: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var type: ElementType
    var rect: NormalizedRect // Values from 0.0 to 1.0 mapped to page width/height to survive resizing
    
    // Aesthetic Overrides
    var colorHex: String? = nil
    var strokeWidth: CGFloat? = nil
    
    // Type-Specific Payloads
    var text: String? = nil
    var targetPageID: UUID? = nil
    var targetURL: String? = nil
    var imageData: Data? = nil // Support for Digital Stickers (PNG/JPEG)
    
    enum ElementType: String, Codable, Hashable {
        case text
        case rectangle
        case circle
        case line
        case image // Digital Sticker
        case linkZone // Invisible Touch Target
    }
}

/// A bounding box defined by normalized percentages (0.0 - 1.0) rather than absolute points.
/// This prevents elements from breaking if the underlying TargetDeviceProfile dimensions change.
struct NormalizedRect: Codable, Hashable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    
    func toCGRect(in bounds: CGSize) -> CGRect {
        return CGRect(
            x: CGFloat(x) * bounds.width,
            y: CGFloat(y) * bounds.height,
            width: CGFloat(width) * bounds.width,
            height: CGFloat(height) * bounds.height
        )
    }
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    
    init(from rect: CGRect, in bounds: CGSize) {
        self.x = Double(rect.origin.x / bounds.width)
        self.y = Double(rect.origin.y / bounds.height)
        self.width = Double(rect.size.width / bounds.width)
        self.height = Double(rect.size.height / bounds.height)
    }
}
