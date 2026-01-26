import Foundation
import SwiftUI
import CoreGraphics
import UIKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Core Data Models

struct ConvertedPDF: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let url: URL
    var pageCount: Int
    let fileSize: Int64
    var metadata: PDFMetadata
    var collectionId: UUID?
    var isFavorite: Bool = false
    var coverImageData: Data?
    
    var formattedSize: String {
        let mb = Double(fileSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    init(id: UUID = UUID(), name: String, url: URL, pageCount: Int, fileSize: Int64, metadata: PDFMetadata, collectionId: UUID? = nil, isFavorite: Bool = false, coverImageData: Data? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.collectionId = collectionId
        self.isFavorite = isFavorite
        self.coverImageData = coverImageData
    }
    
    func toPDFDocument() -> PDFDocument {
        return PDFDocument(url: url) ?? PDFDocument()
    }
}

// ✅ Generic Wrapper for .fileExporter (Handles PDF & EPUB)
struct GenericFileDocument: FileDocument {
    var fileURL: URL
    var tempFileToDelete: URL?
    
    init(url: URL) {
        self.fileURL = url
    }
    
    static var readableContentTypes: [UTType] {
        return [.pdf, .epub, .zip, UTType(filenameExtension: "cbz")!, UTType(filenameExtension: "cbr")!].compactMap { $0 }
    }
    
    init(configuration: ReadConfiguration) throws {
        // We don't really need to read back in this context, but required by protocol
        throw CocoaError(.featureUnsupported)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: fileURL, options: .immediate)
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
    var tags: [String] = []
    // ✅ Calibre-style Reading Options
    var isManga: Bool? // Overrides global setting if present
    var isWebtoon: Bool? // For vertical scroll support
}

struct PDFCollection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
}

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
    case scribeColorsoft = "Kindle Scribe Colorsoft (11\")"
    case colorsoft = "Kindle Colorsoft (7\")"
    case paperwhite2024 = "Kindle Paperwhite (2024)"
    case scribe = "Kindle Scribe (1st Gen)"
    case paperwhite = "Kindle Paperwhite (Older)"
    case oasis = "Kindle Oasis"
    case basic = "Kindle Basic"
    case tablet = "Fire Tablet"
    
    var resolution: CGSize {
        switch self {
        case .scribeColorsoft: return CGSize(width: 1980, height: 2640) // 11" 300ppi
        case .colorsoft: return CGSize(width: 1264, height: 1680) // 7" 300ppi (same as Oasis/PW)
        case .paperwhite2024: return CGSize(width: 1264, height: 1680)
        case .scribe: return CGSize(width: 1860, height: 2480)
        case .paperwhite: return CGSize(width: 1236, height: 1648) // Old PW
        case .oasis: return CGSize(width: 1264, height: 1680)
        case .basic: return CGSize(width: 1080, height: 1440)
        case .tablet: return CGSize(width: 1200, height: 1920)
        }
    }
    
    var icon: String {
        switch self {
        case .scribeColorsoft, .scribe: return "ipad.gen2"
        case .tablet: return "ipad.landscape"
        default: return "book.closed"
        }
    }
}

// MARK: - Settings Models

// ✅ NEW: File Split Modes
enum FileSizeSplitMode: String, CaseIterable, Codable, Identifiable {
    case none = "No Limit (One File)"
    case email = "Email Safe (23 MB)"
    case app = "App Share Safe (47 MB)"
    case web = "Web Safe (190 MB)"
    
    var id: String { rawValue }
    
    // The limit in Bytes
    var limit: Int64 {
        switch self {
        case .none: return Int64.max
        case .email: return 23 * 1024 * 1024
        case .app: return 47 * 1024 * 1024
        case .web: return 190 * 1024 * 1024
        }
    }
    
    var description: String {
        switch self {
        case .none: return "Keep as one large file."
        case .email: return "Splits for 'Send-to-Kindle' Email."
        case .app: return "Splits for Kindle App sharing."
        case .web: return "Splits for 'Send-to-Kindle' Web."
        }
    }
}

// ✅ NEW: Panel Generation Strategy
enum PanelStrategy: String, CaseIterable, Codable, Identifiable {
    case physical = "Physical Splitting (Compatible)"
    case virtual = "Virtual Layout (Experimental)"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .physical: return "Creates separate images for each panel. Best for Send-to-Kindle Email."
        case .virtual: return "Uses metadata to zoom. Smaller file size, but requires USB transfer."
        }
    }
}

// ✅ NEW: App Text Size Preference
enum AppTextSize: String, CaseIterable, Codable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    
    var id: String { rawValue }
    
    var swiftUIValue: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .xxLarge
        }
    }
}

struct ConversionSettings: Codable, Equatable {
    var outputFormat: OutputFormat = .epub
    var compressionQuality: CompressionPreset = .balanced
    var optimizeForDevice: Bool = false
    var targetDevice: KindleDeviceType = .scribe
    var mangaMode: Bool = false
    var enablePanelSplit: Bool = false
    var splitMode: FileSizeSplitMode = .none
    var panelStrategy: PanelStrategy = .physical 
    var textSize: AppTextSize = .medium // ✅ New Preference 
    
    // ✅ Keychain Integration
    // We remove the stored property and use a computed one.
    // For migration, we define a private coding key to read old JSON.
    var comicVineAPIKey: String {
        get {
            if let data = KeychainHelper.standard.read(service: "com.antigravity.InksyncPro", account: "comicVineAPIKey"),
               let key = String(data: data, encoding: .utf8) {
                return key
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                KeychainHelper.standard.delete(service: "com.antigravity.InksyncPro", account: "comicVineAPIKey")
            } else {
                let data = Data(newValue.utf8)
                KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "comicVineAPIKey")
            }
        }
    }
    
    var epubSettings: EPUBSettings = EPUBSettings()
    var imageEnhancement: ImageEnhancementSettings = ImageEnhancementSettings()
    
    // Custom Codable implementation to handle migration
    enum CodingKeys: String, CodingKey {
        case outputFormat, compressionQuality, optimizeForDevice, targetDevice, mangaMode, enablePanelSplit, splitMode, panelStrategy, epubSettings, imageEnhancement, textSize
        case comicVineAPIKey // Used for legacy read only
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputFormat = try container.decode(OutputFormat.self, forKey: .outputFormat)
        compressionQuality = try container.decode(CompressionPreset.self, forKey: .compressionQuality)
        optimizeForDevice = try container.decode(Bool.self, forKey: .optimizeForDevice)
        targetDevice = try container.decode(KindleDeviceType.self, forKey: .targetDevice)
        mangaMode = try container.decode(Bool.self, forKey: .mangaMode)
        enablePanelSplit = try container.decode(Bool.self, forKey: .enablePanelSplit)
        splitMode = try container.decode(FileSizeSplitMode.self, forKey: .splitMode)
        panelStrategy = try container.decodeIfPresent(PanelStrategy.self, forKey: .panelStrategy) ?? .physical
        epubSettings = try container.decode(EPUBSettings.self, forKey: .epubSettings)
        imageEnhancement = try container.decode(ImageEnhancementSettings.self, forKey: .imageEnhancement)
        textSize = try container.decodeIfPresent(AppTextSize.self, forKey: .textSize) ?? .medium
        
        // ⚠️ MIGRATION: Check if JSON contains the legacy key
        if let legacyKey = try? container.decodeIfPresent(String.self, forKey: .comicVineAPIKey), !legacyKey.isEmpty {
            // Save to Keychain
            print("🔐 Migrating Legacy API Key to Keychain...")
            let data = Data(legacyKey.utf8)
            KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "comicVineAPIKey")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outputFormat, forKey: .outputFormat)
        try container.encode(compressionQuality, forKey: .compressionQuality)
        try container.encode(optimizeForDevice, forKey: .optimizeForDevice)
        try container.encode(targetDevice, forKey: .targetDevice)
        try container.encode(mangaMode, forKey: .mangaMode)
        try container.encode(enablePanelSplit, forKey: .enablePanelSplit)
        try container.encode(splitMode, forKey: .splitMode)
        try container.encode(panelStrategy, forKey: .panelStrategy)
        try container.encode(epubSettings, forKey: .epubSettings)
        try container.encode(imageEnhancement, forKey: .imageEnhancement)
        try container.encode(textSize, forKey: .textSize)
        // We purposefully DO NOT encode comicVineAPIKey so it disappears from JSON next save
    }
}

struct EPUBSettings: Codable, Equatable {
    enum ReadingDirection: String, Codable {
        case ltr = "ltr"
        case rtl = "rtl"
    }
    
    // ✅ Export Format (EPUB vs CBZ for Guided View)
    enum GuidedViewExportFormat: String, Codable, CaseIterable, Identifiable {
        case epub = "EPUB"
        case cbz = "CBZ"
        var id: String { rawValue }
    }
    
    var panelDetectionMode: PanelExtractor.ExtractionMode = .automatic
    var includeTableOfContents: Bool = false
    var splitPanels: Bool = false
    var includeFullPage: Bool = true
    var panelDetectionConfidence: Double = 0.6
    var readingDirection: ReadingDirection = .ltr
    var guidedViewExportFormat: GuidedViewExportFormat = .epub
}

struct ImageEnhancementSettings: Codable, Equatable {
    var grayscale: Bool = false
    var autoContrast: Bool = false
    var invertColors: Bool = false
    var brightness: Double = 0.0
    var sharpness: Double = 0.0
    // ✅ KCC: Gamma Correction (Crucial for E-Ink to prevent black crush)
    var gamma: Double = 1.0 
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

struct DeletablePageItem: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let thumbnail: UIImage
    var isSelected: Bool
    var imageURL: URL? = nil
}

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

// MARK: - Manifest
struct EPUBPanelManifest: Codable {
    struct PageInfo: Codable {
        let pageIndex: Int
        var panels: [PanelExtractor.Panel]
    }
    var pages: [PageInfo] = []
}
