import Foundation
import SwiftUI
import CoreGraphics

// MARK: - Core Data Models

struct ConvertedPDF: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    let url: URL
    let pageCount: Int
    let fileSize: Int64
    var metadata: PDFMetadata
    var collectionId: UUID?
    
    // Quick Formatted Size
    var formattedSize: String {
        let mb = Double(fileSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    init(id: UUID = UUID(), name: String, url: URL, pageCount: Int, fileSize: Int64, metadata: PDFMetadata, collectionId: UUID? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.collectionId = collectionId
    }
}

struct PDFMetadata: Codable, Equatable, Hashable {
    var title: String
    var author: String?
    var series: String?
    var issueNumber: String?
    var publisher: String?
    var publicationDate: Date?
    var summary: String?
}

struct PDFCollection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var color: String // Hex or name
    var creationDate: Date
}

struct KindleDevice: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var type: KindleDeviceType
    var isDefault: Bool
    
    init(id: UUID = UUID(), name: String, email: String, type: KindleDeviceType, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.email = email
        self.type = type
        self.isDefault = isDefault
    }
}

enum KindleDeviceType: String, CaseIterable, Codable, Hashable {
    case scribe = "Kindle Scribe"
    case paperwhite = "Kindle Paperwhite"
    case oasis = "Kindle Oasis"
    case basic = "Kindle Basic"
    case tablet = "Fire Tablet"
    
    var resolution: CGSize {
        switch self {
        case .scribe: return CGSize(width: 1860, height: 2480)
        case .paperwhite: return CGSize(width: 1236, height: 1648)
        case .oasis: return CGSize(width: 1264, height: 1680)
        case .basic: return CGSize(width: 1080, height: 1440)
        case .tablet: return CGSize(width: 1200, height: 1920)
        }
    }
    
    var icon: String {
        switch self {
        case .scribe: return "ipad.gen2"
        case .tablet: return "ipad.landscape"
        default: return "book.closed"
        }
    }
}

// MARK: - Settings Models

struct ConversionSettings: Codable, Equatable {
    var outputFormat: OutputFormat = .epub
    var compressionQuality: CompressionPreset = .balanced
    var optimizeForDevice: Bool = false
    var targetDevice: KindleDeviceType = .scribe
    var mangaMode: Bool = false // Right-to-Left
    var enablePanelSplit: Bool = false
    var epubSettings: EPUBSettings = EPUBSettings()
    var imageEnhancement: ImageEnhancementSettings = ImageEnhancementSettings()
}

struct EPUBSettings: Codable, Equatable {
    enum PanelDetectionMode: String, Codable, CaseIterable {
        case automatic
        case conservative
        case aggressive
        case grid // Special case handled in logic
        
        // Helper for UI
        var title: String { rawValue.capitalized }
    }
    
    // Since 'grid' needs associated values in logic but we need Codable here,
    // we store the mode as an enum and separate grid config if needed.
    // For simplicity in this fix, we map the Logic Mode to a simple Codable struct.
    var panelDetectionMode: PanelExtractor.ExtractionMode = .automatic
}

struct ImageEnhancementSettings: Codable, Equatable {
    var grayscale: Bool = false
    var autoContrast: Bool = false
    var invertColors: Bool = false
    var brightness: Double = 0.0
    var sharpness: Double = 0.0
}

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case epub = "EPUB (Kindle)"
    case pdf = "PDF"
    case cbz = "CBZ"
    
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .epub: return "book.fill"
        case .pdf: return "doc.text.fill"
        case .cbz: return "archivebox.fill"
        }
    }
}

enum CompressionPreset: String, CaseIterable, Codable {
    case high = "High Quality"
    case balanced = "Balanced"
    case compact = "Compact"
    
    var value: CGFloat {
        switch self {
        case .high: return 0.9
        case .balanced: return 0.75
        case .compact: return 0.5
        }
    }
}

struct ConversionPreset: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var settings: ConversionSettings
}

// MARK: - Editor Models

// ✅ Fix: Simplified Session for Single Page Editing
struct PanelEditSession: Identifiable {
    let id: UUID
    var originalImage: UIImage?
    var panels: [PanelExtractor.Panel]
    
    init(id: UUID = UUID(), originalImage: UIImage?, panels: [PanelExtractor.Panel]) {
        self.id = id
        self.originalImage = originalImage
        self.panels = panels
    }
}

struct AppBackgroundTask: Identifiable {
    let id: UUID
    var title: String
    var progress: Double
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let files: [ConvertedPDF]
    let totalSize: Int64
}

struct StorageInfo {
    let used: Int64
    let totalSize: Int64
    let appUsage: Int64
    
    var usedFormatted: String { ByteCountFormatter.string(fromByteCount: used, countStyle: .file) }
    var totalFormatted: String { ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file) }
}

struct BackupData: Codable {
    let version: String
    let date: Date
    let settings: ConversionSettings
    let collections: [PDFCollection]
    let presets: [ConversionPreset]
}
