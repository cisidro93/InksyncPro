import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Core Models

struct ConvertedPDF: Identifiable, Codable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    let dateAdded: Date = Date()
    let pageCount: Int
    let fileSize: Int64
    var metadata: PDFMetadata?
    var collectionId: UUID?
    
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
}

// MARK: - Settings & Config

struct ConversionSettings: Codable, Equatable {
    var outputFormat: OutputFormat = .epub
    var compressionQuality: Double = 0.8
    var epubSettings: EPUBSettings = EPUBSettings()
    var enablePanelSplit: Bool = false // Fixed missing property
}

struct EPUBSettings: Codable, Equatable {
    var splitPanels: Bool = false
    var mangaMode: Bool = false
    var readingDirection: ReadingDirection = .leftToRight
    var useFixedLayout: Bool = true // Fixed
    
    enum ReadingDirection: String, Codable, Equatable, CaseIterable {
        case leftToRight = "Left to Right"
        case rightToLeft = "Right to Left"
        case vertical = "Vertical"
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case pdf = "PDF"
    case epub = "EPUB"
    var id: String { rawValue }
    var icon: String { self == .pdf ? "doc.text.fill" : "book.fill" }
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
}

struct BackupData: Codable {
    let version: String
    let date: Date
    let settings: ConversionSettings
    let collections: [PDFCollection]
    let presets: [ConversionPreset]
}

// MARK: - Task & Panels

struct BackgroundTask: Identifiable {
    let id = UUID()
    let description: String
}

struct PanelEditSession {
    struct PageEditData {
        let pageNumber: Int
        let imageURL: URL
        // Placeholder for EditablePanel to fix dependencies
        let panels: [Any] = [] 
    }
    let pages: [PageEditData]
    let readingDirection: EPUBSettings.ReadingDirection
    let sessionTempDirectory: URL
}

// Stub for EditablePanel to satisfy build if needed elsewhere
struct EditablePanel: Identifiable {
    let id = UUID()
    let rect: CGRect
    let order: Int
}
