import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Core Models

struct ConvertedPDF: Identifiable, Codable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    var dateAdded: Date = Date()
    let pageCount: Int
    let fileSize: Int64
    var metadata: PDFMetadata?
    var collectionId: UUID?
    var isFavorite: Bool = false // Fixed missing member
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

struct PDFMetadata: Codable, Equatable {
    var title: String
    var author: String = ""
    var publisher: String = ""
    var series: String = "" // Fixed missing member
    var summary: String = "" // Fixed missing member
    var tags: [String] = []
}

struct PDFCollection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let fileHash: String
    let items: [ConvertedPDF]
    // Helper for UI
    var files: [ConvertedPDF] { items }
}

// MARK: - Settings

struct ConversionSettings: Codable, Equatable {
    var outputFormat: OutputFormat = .epub
    var compressionQuality: Double = 0.8
    var epubSettings: EPUBSettings = EPUBSettings()
    var targetDevice: String = "Kindle Scribe"
    var enablePanelSplit: Bool = false
    var comicVineAPIKey: String = "" // Fixed missing member
    
    // Proxy for UI convenience if needed, though Views should use epubSettings
    var mangaMode: Bool {
        get { epubSettings.mangaMode }
        set { epubSettings.mangaMode = newValue }
    }
    
    var imageEnhancement = ImageEnhancementSettings()
    var optimizeForDevice: Bool = false
}

struct ImageEnhancementSettings: Codable, Equatable {
    var enabled: Bool = false
    var contrast: Double = 1.0
}

struct EPUBSettings: Codable, Equatable {
    var splitPanels: Bool = false
    var mangaMode: Bool = false {
        didSet { readingDirection = mangaMode ? .rightToLeft : .leftToRight }
    }
    var enablePanelView: Bool = true
    var useFixedLayout: Bool = true
    var includeTableOfContents: Bool = true
    var panelDetectionMode: PanelExtractor.ExtractionMode = .automatic
    
    enum ReadingDirection: String, Codable, Equatable, CaseIterable {
        case leftToRight = "Left to Right"
        case rightToLeft = "Right to Left"
        case vertical = "Vertical"
    }
    
    var readingDirection: ReadingDirection = .leftToRight
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case pdf = "PDF"
    case epub = "EPUB"
    case both = "PDF & EPUB" // Fixed missing case
    var id: String { rawValue }
    var icon: String { "doc.on.doc" }
}

enum OrganizationMethod: String, CaseIterable, Identifiable, Codable {
    case dateAdded = "Date Added"
    case alphabetical = "Alphabetical"
    case fileSize = "File Size"
    var id: String { rawValue }
}

struct ConversionPreset: Identifiable, Codable {
    let id = UUID()
    var name: String
    var settings: ConversionSettings
    var icon: String = "gearshape"
    var isDefault: Bool = false // Fixed missing member
}

struct BackupData: Codable {
    let version: String
    let date: Date
    let settings: ConversionSettings
    let collections: [PDFCollection]
    let presets: [ConversionPreset]
}

// MARK: - Panel Editing (Consolidated here)

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
    struct PageEditData {
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

// MARK: - Tasks

struct BackgroundTask: Identifiable {
    let id = UUID()
    let description: String
}

// Stub for PageItem to satisfy PageReorderView
struct PageItem: Identifiable, Equatable {
    let id = UUID()
    let originalIndex: Int
    var currentIndex: Int
    let thumbnail: UIImage
}
