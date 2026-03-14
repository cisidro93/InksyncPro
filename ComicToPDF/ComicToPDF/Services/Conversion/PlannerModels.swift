import Foundation
import UIKit
import PencilKit

/// Core Data Structure for an Editable Inksync Planner Project (*.inksycPlanner)
struct PlannerProject: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var creationDate: Date = Date()
    var isFavorite: Bool = false
    var targetDeviceProfile: TargetDeviceProfile = .original
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
    
    // Explicit Codable Synthesis guarantees
    init(id: UUID = UUID(), type: ElementType, rect: NormalizedRect, colorHex: String? = nil, strokeWidth: CGFloat? = nil, text: String? = nil, targetPageID: UUID? = nil, targetURL: String? = nil, imageData: Data? = nil) {
        self.id = id
        self.type = type
        self.rect = rect
        self.colorHex = colorHex
        self.strokeWidth = strokeWidth
        self.text = text
        self.targetPageID = targetPageID
        self.targetURL = targetURL
        self.imageData = imageData
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.type = try container.decode(ElementType.self, forKey: .type)
        self.rect = try container.decode(NormalizedRect.self, forKey: .rect)
        self.colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        self.strokeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .strokeWidth)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.targetPageID = try container.decodeIfPresent(UUID.self, forKey: .targetPageID)
        self.targetURL = try container.decodeIfPresent(String.self, forKey: .targetURL)
        self.imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(rect, forKey: .rect)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(targetPageID, forKey: .targetPageID)
        try container.encodeIfPresent(targetURL, forKey: .targetURL)
        try container.encodeIfPresent(imageData, forKey: .imageData)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, rect, colorHex, strokeWidth, text, targetPageID, targetURL, imageData
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(rect)
    }
    
    static func == (lhs: PlannerElement, rhs: PlannerElement) -> Bool {
        return lhs.id == rhs.id && lhs.type == rhs.type && lhs.rect == rhs.rect
    }
}

// Removed NormalizedRect to avoid collision with NormalizedCoordinate.swift
