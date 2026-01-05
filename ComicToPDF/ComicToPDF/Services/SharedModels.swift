import SwiftUI
import PDFKit
import CoreImage
import ZIPFoundation
import UIKit
import CryptoKit

// ============================================================================
// MARK: - MODELS
// ============================================================================

struct ConvertedPDF: Identifiable, Codable {
    let id: UUID
    var name: String
    let url: URL
    let dateAdded: Date
    var pageCount: Int
    let fileSize: Int64
    var collectionId: UUID?
    var metadata: PDFMetadata
    var isFavorite: Bool = false
    var coverImageData: Data? = nil
    var fileHash: String? = nil
    var lastSentDate: Date? = nil
    var lastSentDevice: String? = nil
    
    // Advanced Features
    var bookmarks: [Int]? = []
    var lastReadPage: Int? = 0
    var readingProgress: Double? = 0.0
    var format: OutputFormat? // Optional, inferred from URL if nil
    
    init(name: String, url: URL, pageCount: Int, fileSize: Int64, collectionId: UUID? = nil, metadata: PDFMetadata? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.dateAdded = Date()
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.collectionId = collectionId
        self.metadata = metadata ?? PDFMetadata()
    }
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

struct PDFMetadata: Codable {
    var title: String = ""
    var author: String = ""
    var series: String = ""
    var volume: String = ""
    var genre: String = ""
    var tags: [String] = []
    var notes: String = ""
    var summary: String = ""
    var publisher: String = ""
}

struct PDFCollection: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    let dateCreated: Date
    
    init(name: String, icon: String = "folder.fill", color: String = "blue") {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.color = color
        self.dateCreated = Date()
    }
}

struct KindleDevice: Identifiable, Codable {
    let id: UUID
    var name: String
    var email: String
    var deviceType: KindleDeviceType
    var isDefault: Bool
    
    init(name: String, email: String, deviceType: KindleDeviceType = .paperwhite, isDefault: Bool = false) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.deviceType = deviceType
        self.isDefault = isDefault
    }
}

enum KindleDeviceType: String, Codable, CaseIterable {
    case paperwhite = "Paperwhite"
    case oasis = "Oasis"
    case scribe = "Scribe"
    case basic = "Kindle"
    case fire = "Fire Tablet"
    case app = "Kindle App"
    
    var resolution: CGSize {
        switch self {
        case .paperwhite: return CGSize(width: 1236, height: 1648)
        case .oasis: return CGSize(width: 1264, height: 1680)
        case .scribe: return CGSize(width: 1860, height: 2480)
        case .basic: return CGSize(width: 1072, height: 1448)
        case .fire: return CGSize(width: 1200, height: 1920)
        case .app: return CGSize(width: 1536, height: 2048)
        }
    }
    
    var icon: String {
        switch self {
        case .paperwhite, .oasis, .basic: return "book.closed.fill"
        case .scribe: return "pencil.and.scribble"
        case .fire, .app: return "ipad"
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case pdf = "PDF"
    case epub = "EPUB"
    case both = "Both"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .pdf: return "doc.text.fill"
        case .epub: return "book.fill"
        case .both: return "doc.on.doc.fill"
        }
    }
}

struct ConversionSettings: Codable, Equatable {
    var mangaMode: Bool = false
    var compressionQuality: CompressionPreset = .high
    var customScale: Double = 1.0
    var customJpegQuality: Double = 0.85
    var targetDevice: KindleDeviceType = .paperwhite
    var optimizeForDevice: Bool = false
    var imageEnhancement: ImageEnhancementSettings = ImageEnhancementSettings()
    var outputFormat: OutputFormat = .pdf
    var epubSettings: EPUBSettings = EPUBSettings()
    
    var enablePanelSplit: Bool = false
    var comicVineAPIKey: String = ""
}

struct ImageEnhancementSettings: Codable, Equatable {
    var enabled: Bool = false
    var autoContrast: Bool = false
    var brightness: Double = 0.0
    var contrast: Double = 1.0
    var sharpness: Double = 0.0
    var saturation: Double = 1.0
    var grayscale: Bool = false
    var invertColors: Bool = false
}

enum CompressionPreset: String, Codable, CaseIterable {
    case original = "Original"
    case high = "High Quality"
    case balanced = "Balanced"
    case compact = "Compact"
    case custom = "Custom"
    
    var values: (scale: Double, quality: Double) {
        switch self {
        case .original: return (1.0, 1.0)
        case .high: return (1.0, 0.9)
        case .balanced: return (0.85, 0.8)
        case .compact: return (0.7, 0.7)
        case .custom: return (1.0, 0.85)
        }
    }
}

enum ConversionError: LocalizedError {
    case noImagesFound
    case unsupportedFormat
    case pdfCreationFailed
    case compressionFailed
    case conversionFailed
    
    var errorDescription: String? {
        switch self {
        case .noImagesFound: return "No images found in the archive"
        case .unsupportedFormat: return "Unsupported archive format"
        case .pdfCreationFailed: return "Failed to create PDF"
        case .compressionFailed: return "Failed to compress images"
        case .conversionFailed: return "Conversion failed"
        }
    }
}

struct EPUBSettings: Codable, Equatable {
    var useFixedLayout: Bool = true
    var includeTableOfContents: Bool = true
    var readingDirection: ReadingDirection = .leftToRight
    var preserveAspectRatio: Bool = true
    var includeMetadata: Bool = true
    var embedFonts: Bool = false
    
    var enablePanelView: Bool = false
    var panelDetectionMode: PanelDetectionMode = .automatic
    var panelMinSize: Double = 0.05
    var panelMaxSize: Double = 0.90
    var splitPanels: Bool = false
    
    enum ReadingDirection: String, CaseIterable, Codable {
        case leftToRight = "ltr"
        case rightToLeft = "rtl"
        
        var displayName: String {
            switch self {
            case .leftToRight: return "Left to Right (Western)"
            case .rightToLeft: return "Right to Left (Manga)"
            }
        }
    }
    
    enum PanelDetectionMode: String, CaseIterable, Codable {
        case automatic = "auto"
        case grid2x2 = "grid_2x2"
        case grid3x3 = "grid_3x3"
        case grid2x3 = "grid_2x3"
        
        var displayName: String {
            switch self {
            case .automatic: return "Automatic Detection"
            case .grid2x2: return "2×2 Grid"
            case .grid3x3: return "3×3 Grid"
            case .grid2x3: return "2×3 Grid"
            }
        }
    }
}

struct PageItem: Identifiable, Equatable {
    let id = UUID()
    let originalIndex: Int
    var currentIndex: Int
    let thumbnail: UIImage
    
    static func == (lhs: PageItem, rhs: PageItem) -> Bool {
        lhs.id == rhs.id
    }
}

class BackgroundTask: Identifiable, ObservableObject {
    let id: UUID
    let description: String
    let dateStarted: Date
    @Published var progress: Double = 0
    
    init(description: String) {
        self.id = UUID()
        self.description = description
        self.dateStarted = Date()
    }
}

struct ConversionQueueItem: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let settings: ConversionSettings
    var progress: Double = 0
    var status: ConversionStatus = .pending
    
    enum ConversionStatus {
        case pending
        case converting
        case completed
        case failed(Error)
    }
}
