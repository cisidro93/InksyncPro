import Foundation
import SwiftUI
import CoreGraphics

// MARK: - Core Data Models

struct ConvertedPDF: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    let url: URL
    var pageCount: Int
    let fileSize: Int64
    var metadata: PDFMetadata
    var collectionId: UUID?
    var isFavorite: Bool = false // ✅ Added
    
    var formattedSize: String {
        let mb = Double(fileSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    init(id: UUID = UUID(), name: String, url: URL, pageCount: Int, fileSize: Int64, metadata: PDFMetadata, collectionId: UUID? = nil, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.collectionId = collectionId
        self.isFavorite = isFavorite
    }
}

struct PDFMetadata: Codable, Equatable, Hashable {
    var title: String
    var author: String?
    var series: String?
    var issueNumber: String?
    var volume: String?
    var publisher: String?
    var publicationDate: Date?
    var summary: String?
    var tags: [String] = [] // ✅ Added
}

// ... (Rest of file remains unchanged until EPUBPanelManifest)

// ✅ Stub for EPUBMerger legacy code
struct EPUBPanelManifest: Codable {
    var pages: [PageInfo] = []
    
    struct PageInfo: Codable {
        var pageNumber: Int
        var panels: [PanelExtractor.Panel]
    }
}

struct PDFCollection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
}

// ✅ Helper for LibraryGridItem
func colorFor(_ name: String) -> Color {
    switch name.lowercased() {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "purple": return .purple
    default: return .blue
    }
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
    var mangaMode: Bool = false
    var enablePanelSplit: Bool = false
    var comicVineAPIKey: String = "" // ✅ Added
    var epubSettings: EPUBSettings = EPUBSettings()
    var imageEnhancement: ImageEnhancementSettings = ImageEnhancementSettings()
}

struct EPUBSettings: Codable, Equatable {
    var panelDetectionMode: PanelExtractor.ExtractionMode = .automatic
    var includeTableOfContents: Bool = true // ✅ Added
    var splitPanels: Bool = false // ✅ Added (Legacy alias)
    var enablePanelView: Bool = false // ✅ Added (Legacy alias)
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

struct PageItem: Identifiable, Equatable {
    let id = UUID()
    let originalIndex: Int
    var currentIndex: Int
    let thumbnail: UIImage
}

// MARK: - Task & App Models

class AppBackgroundTask: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var progress: Double
    
    init(id: UUID = UUID(), title: String, progress: Double) {
        self.id = id
        self.title = title
        self.progress = progress
    }
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

// ✅ Stub for EPUBMerger legacy code
// ✅ Stub for EPUBMerger legacy code
struct EPUBPanelManifest: Codable {
    var pages: [PageInfo] = []
    
    struct PageInfo: Codable {
        var pageNumber: Int
        var panels: [PanelExtractor.Panel]
    }
}
