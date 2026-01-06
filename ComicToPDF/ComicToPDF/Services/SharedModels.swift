import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Core Models

struct ConvertedPDF: Identifiable, Codable, Equatable {
    var id = UUID()
    let name: String
    let url: URL
    var dateAdded: Date = Date()
    var pageCount: Int
    let fileSize: Int64
    var metadata: PDFMetadata = PDFMetadata(title: "Untitled")
    var collectionId: UUID?
    var isFavorite: Bool = false
    var coverImageData: Data? = nil 
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

struct PDFMetadata: Codable, Equatable {
    var title: String = ""
    var author: String = ""
    var publisher: String = ""
    var series: String = ""
    var volume: String = ""
    var summary: String = ""
    var tags: [String] = []
    
    init(title: String = "") {
        self.title = title
    }
}

struct PDFCollection: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let fileHash: String
    let items: [ConvertedPDF]
    var files: [ConvertedPDF] { items }
}

// MARK: - Settings

struct ConversionSettings: Codable, Equatable {
    var outputFormat: OutputFormat = .epub
    var compressionQuality: Double = 0.8
    var epubSettings: EPUBSettings = EPUBSettings()
    var targetDevice: String = "Kindle Scribe"
    var enablePanelSplit: Bool = false
    var comicVineAPIKey: String = ""
    var optimizeForDevice: Bool = false
    var imageEnhancement = ImageEnhancementSettings()
    
    // Helper so binding works
    var mangaMode: Bool {
        get { epubSettings.mangaMode }
        set { epubSettings.mangaMode = newValue }
    }
}

struct ImageEnhancementSettings: Codable, Equatable {
    var enabled: Bool = false
    var autoContrast: Bool = false
    var grayscale: Bool = false
    var invertColors: Bool = false
    var contrast: Double = 1.0
    var brightness: Double = 0.0
    var sharpness: Double = 0.0 // ✅ Added
}

struct EPUBSettings: Codable, Equatable {
    var splitPanels: Bool = false
    var mangaMode: Bool = false
    var readingDirection: ReadingDirection = .leftToRight
    var useFixedLayout: Bool = true
    var enablePanelView: Bool = true
    var includeTableOfContents: Bool = true
    var panelDetectionMode: PanelExtractor.ExtractionMode = .automatic
    
    enum ReadingDirection: String, Codable, Equatable, CaseIterable {
        case leftToRight = "Left to Right"
        case rightToLeft = "Right to Left"
        case vertical = "Vertical"
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case pdf = "PDF"
    case epub = "EPUB"
    case both = "PDF & EPUB"
    var id: String { rawValue }
    var icon: String { "doc.on.doc" }
}

enum CompressionPreset: String, CaseIterable, Codable {
    case original = "Original"
    case high = "High Quality"
    case balanced = "Balanced"
    case compact = "Compact"
    case custom = "Custom"
}

enum KindleDeviceType: String, CaseIterable, Codable {
    case scribe = "Kindle Scribe"
    case paperwhite = "Kindle Paperwhite"
    case oasis = "Kindle Oasis"
    case basic = "Kindle Basic"
    case app = "Kindle App"
    var icon: String { "ipad.gen2" }
}

struct KindleDevice: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var email: String
    var deviceType: KindleDeviceType
    var isDefault: Bool
}

// MARK: - Storage & System

struct StorageInfo {
    let used: Int64
    let totalSize: Int64
    let appUsage: Int64
}

struct ConversionPreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var settings: ConversionSettings
    var icon: String = "gearshape"
    var isDefault: Bool = false
}

struct BackupData: Codable {
    let version: String
    let date: Date
    let settings: ConversionSettings
    let collections: [PDFCollection]
    let presets: [ConversionPreset]
}

struct SendHistoryRecord: Identifiable, Codable { // ✅ Added
    let id: UUID
    let fileName: String
    let dateSent: Date
    let deviceName: String
}

// MARK: - Tasks

class BackgroundTask: ObservableObject, Identifiable {
    let id = UUID()
    let description: String
    @Published var progress: Double = 0.0
    
    init(description: String) {
        self.description = description
    }
}

// MARK: - Panels & Manifest

struct EPUBPanelManifest: Codable, Equatable { // ✅ Added
    struct PagePanels: Codable, Equatable {
        let pageNumber: Int
        let imageFile: String
        let panels: [PanelRegion]
    }
    let pages: [PagePanels]
}

struct PanelRegion: Codable, Equatable { // ✅ Added
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let pageIndex: Int
    
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct EditablePanel: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    var order: Int
    
    init(id: UUID = UUID(), rect: CGRect, order: Int) {
        self.id = id
        self.rect = rect
        self.order = order
    }
}

class PanelEditSession: ObservableObject, Identifiable {
    let id = UUID()
    
    struct PageEditData: Identifiable {
        let id = UUID()
        let pageNumber: Int
        let imageURL: URL
        var panels: [EditablePanel]
    }
    
    @Published var pages: [PageEditData]
    let readingDirection: EPUBSettings.ReadingDirection
    let sessionTempDirectory: URL
    
    init(pages: [PageEditData], readingDirection: EPUBSettings.ReadingDirection, sessionTempDirectory: URL) {
        self.pages = pages
        self.readingDirection = readingDirection
        self.sessionTempDirectory = sessionTempDirectory
    }
}

struct PageItem: Identifiable, Equatable {
    let id = UUID()
    let originalIndex: Int
    var currentIndex: Int
    let thumbnail: UIImage
}
