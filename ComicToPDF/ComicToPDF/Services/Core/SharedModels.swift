import Foundation
import SwiftData
import SwiftUI
import CoreGraphics
import UIKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Core Data Models

// âœ… NEW: Unified App UI Mode
enum AppUIMode: String, Codable, CaseIterable {
    case go = "Go"
    case pro = "Pro"
}

// âœ… NEW: Global Library Tap Action
enum LibraryTapAction: String, CaseIterable {
    case details = "Tap for Details"
    case read = "Tap to Read"
}

// âœ… NEW: Content Type Classification
enum ContentType: String, Codable, CaseIterable {
    case comic = "Comic"
    case manga = "Manga"
    case book = "Book"
    case hybrid = "Hybrid"
    
    var icon: String {
        switch self {
        case .comic: return "book.closed"
        case .manga: return "text.book.closed"
        case .book: return "text.alignleft"
        case .hybrid: return "doc.richtext"
        }
    }
    
    var badgeColor: Color {
        switch self {
        case .comic: return .blue
        case .manga: return .purple
        case .book: return .green
        case .hybrid: return .orange
        }
    }
    
    var supportsGuidedView: Bool {
        switch self {
        case .comic, .manga: return true
        case .book: return false
        case .hybrid: return true  // User can toggle
        }
    }
}

// âœ… NEW: Unified Reader Content Kinds
enum ContentKind: String, Codable {
    case comic       // CBZ, CBR, CB7, CBT
    case book        // EPUB, MOBI
    case document    // PDF
}

enum DocumentSubtype: String, Codable {
    case researchPaper
    case magazine
    case manual
    case unknown
}

struct ConvertedPDF: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var parentFolderID: UUID? = nil
    
    // Core Data Sync fields
    var dataSyncHash: String? = nil
    var lastModified: Date = Date()
    var pageCount: Int
    var fileSize: Int64
    var metadata: PDFMetadata
    var collectionId: UUID?
    var isFavorite: Bool = false
    var isPrivate: Bool = false // âœ… NEW: Privacy Flag
    var isExplicitSeriesCover: Bool = false
    var coverImageData: Data?
    var contentType: ContentType = .comic  // âœ… NEW: Track content type
    var chapters: [Chapter] = [] // âœ… NEW: Detected Chapters
    var addedByMode: AppUIMode = .pro // âœ… NEW: Track source UI mode
    
    // âœ… NEW: Unified Reader Properties
    var contentKind: ContentKind = .comic
    var documentSubtype: DocumentSubtype = .unknown
    var isOnDevice: Bool = false
    var lastTransferFailed: Bool = false
    var lastOutputFormat: OutputFormat? = nil
    var lastConversionDate: Date? = nil
    var panelConfidenceScore: Double? = nil
    
    // SHA-256 content hash, set ONCE at import. Never update during rename, edit, or metadata refresh.
    var contentHash: String? = nil
    
    // âœ… NEW: File Extension Tracker
    var fileExtensionString: String {
        return url.pathExtension.uppercased()
    }
    
    var formattedSize: String {
        let mb = Double(fileSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    init(id: UUID = UUID(), name: String, url: URL, pageCount: Int, fileSize: Int64, metadata: PDFMetadata, collectionId: UUID? = nil, isFavorite: Bool = false, isPrivate: Bool = false, coverImageData: Data? = nil, contentType: ContentType = .comic, chapters: [Chapter] = [], addedByMode: AppUIMode = .pro, contentHash: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.collectionId = collectionId
        self.isFavorite = isFavorite
        self.isPrivate = isPrivate
        self.isExplicitSeriesCover = false
        self.coverImageData = coverImageData
        self.contentType = contentType
        self.chapters = chapters
        self.addedByMode = addedByMode
        self.contentKind = .comic
        self.documentSubtype = .unknown
        self.isOnDevice = false
        self.lastTransferFailed = false
        self.lastOutputFormat = nil
        self.lastConversionDate = nil
        self.panelConfidenceScore = nil
    }
    
    func toPDFDocument() -> PDFDocument {
        return PDFDocument(url: url) ?? PDFDocument()
    }
    
    // âœ… NEW: Explicit Equatable & Hashable for Core Rendering Performance
    // Instead of diffing the massive tree of metadata, dates, and chapters on every frame,
    // SwiftUI will now only compare the immutable ID, favorite status, name, and page count.
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(isFavorite)
        hasher.combine(pageCount)
        hasher.combine(fileSize)
        hasher.combine(isPrivate)
        hasher.combine(metadata.series)
    }

    static func == (lhs: ConvertedPDF, rhs: ConvertedPDF) -> Bool {
        // Fast paths to bypass heavy layout equality checks
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.isFavorite == rhs.isFavorite &&
               lhs.pageCount == rhs.pageCount &&
               lhs.fileSize == rhs.fileSize &&
               lhs.isPrivate == rhs.isPrivate &&
               lhs.metadata.series == rhs.metadata.series
    }
}

// âœ… Shared Error Type
enum ConversionError: Error {
    case invalidFormat
    case archiveCreationFailed
    case missingMetadata
    case cancelled
}

// ... existing code
struct GenericFileDocument: FileDocument {
    var fileURL: URL
    var tempFileToDelete: URL?
    
    init(url: URL) {
        self.fileURL = url
    }
    
    static var readableContentTypes: [UTType] {
        return [.pdf, .epub, .zip, UTType(filenameExtension: "cbz")!].compactMap { $0 }
    }
    
    init(configuration: ReadConfiguration) throws {
        // We don't really need to read back in this context, but required by protocol
        throw CocoaError(.featureUnsupported)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: fileURL, options: .immediate)
    }
}

struct PDFMetadata: Codable, Equatable, Hashable, Sendable {
    var title: String
    var author: String?
    var series: String?
    var issueNumber: String?
    var volume: String?
    var publisher: String?
    var publicationDate: Date?
    var summary: String?
    // âœ… Rich Metadata
    var writer: String?
    var penciller: String?
    
    // âœ… LEGACY PROPERTIES
    @available(*, deprecated, message: "Use universalIssueID instead")
    var comicVineID: Int?
    @available(*, deprecated, message: "Use universalSeriesID instead")
    var seriesID: Int?
    
    // âœ… Polymorphic String IDs
    var externalSeriesID: String?
    var externalIssueID: String?
    
    var universalSeriesID: String? {
        get { externalSeriesID ?? universalSeriesID }
        set { externalSeriesID = newValue }
    }
    
    var universalIssueID: String? {
        get { externalIssueID ?? universalIssueID }
        set { externalIssueID = newValue }
    }
    
    var tags: [String] = []
    // Reading Progress
    public var lastReadPage: Int?
    
    // âœ… NEW: Advanced Cover Variants Tracking
    public var selectedCoverID: UUID? = nil
    public var coverVariants: [UUID: URL] = [:]
    // âœ… Calibre-style Reading Options
    var isManga: Bool? // Overrides global setting if present
    var isWebtoon: Bool? // For vertical scroll support
    var bookmarkedPages: [Int] = [] // Stores indices of dog-eared pages
    var autoMatchFailed: Bool? = false
}

// âœ… NEW: Chapter Structure
struct Chapter: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var pageIndex: Int // 0-based index of the start page
}

struct PDFCollection: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
    var explicitCoverFileID: UUID?
    var manualSortOrder: [UUID]? = nil // ENFORCED reading order
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

struct KindleDevice: Identifiable, Codable, Equatable, Hashable, Sendable {
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
        case .scribeColorsoft: return CGSize(width: 1980, height: 2640) // 11" 300ppi (Approximately)
        case .colorsoft: return CGSize(width: 1264, height: 1680) // 7" 300ppi
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

// âœ… NEW: Target E-Ink Device Profiles for Downsampling
enum TargetDeviceProfile: String, CaseIterable, Codable, Identifiable {
    // Original Size (No Scaling)
    case original = "Original Size (No Optimization)"
    
    // Amazon Kindle (Sorted by Release Year, Descending)
    case scribeColorsoft = "Kindle Scribe Colorsoft 11\" (2025)"  // 11-inch — NOT the same as the 7" Colorsoft
    case colorsoft7       = "Kindle Colorsoft 7\" (2024)"          // 7-inch colour reader — separate device
    case paperwhite2024  = "Kindle Paperwhite (2024)"
    case scribe          = "Kindle Scribe (2022)"
    case paperwhite11    = "Kindle Paperwhite 11th Gen (2021)"
    case oasis           = "Kindle Oasis (2019)"
    case kindleBasic     = "Kindle Basic (2022)"

    // Kobo
    case koboLibraColour = "Kobo Libra Colour (2024)"
    case koboClaraColour = "Kobo Clara Colour (2024)"
    case koboElipsa2E = "Kobo Elipsa 2E (2023)"
    case koboSage = "Kobo Sage (2021)"
    case koboLibra2 = "Kobo Libra 2 (2021)"
    
    // Onyx Boox
    case booxTabUltraCPro = "Boox Tab Ultra C Pro (2023)"
    case booxNoteAir3C = "Boox Note Air3 C (2023)"
    case booxPage = "Boox Page (2023)"
    case booxPalma = "Boox Palma (2023)"
    
    var id: String { rawValue }
    
    var brand: String {
        switch self {
        case .original: return "General"
        case .scribeColorsoft, .colorsoft7, .paperwhite2024, .scribe, .paperwhite11, .oasis, .kindleBasic: return "Amazon Kindle"
        case .koboLibraColour, .koboClaraColour, .koboElipsa2E, .koboSage, .koboLibra2: return "Rakuten Kobo"
        case .booxTabUltraCPro, .booxNoteAir3C, .booxPage, .booxPalma: return "Onyx Boox"
        }
    }
    
    var resolution: CGSize? {
        // Portrait (taller) resolution — the EInkOptimizer aspect-fits into these bounds.
        switch self {
        case .original: return nil

        // Amazon Kindle
        // Kindle Scribe Colorsoft 11" (2025): 300 PPI → 1980 × 2640
        case .scribeColorsoft: return CGSize(width: 1980, height: 2640)
        // Kindle Colorsoft 7" (2024): 300 PPI → 1264 × 1680 — SEPARATE device, different physical dimensions
        case .colorsoft7:       return CGSize(width: 1264, height: 1680)
        case .paperwhite2024: return CGSize(width: 1264, height: 1680)
        case .scribe:         return CGSize(width: 1860, height: 2480)
        case .paperwhite11:   return CGSize(width: 1236, height: 1648)
        case .oasis:          return CGSize(width: 1264, height: 1680)
        case .kindleBasic:    return CGSize(width: 1080, height: 1440)

        // Kobo
        case .koboLibraColour: return CGSize(width: 1264, height: 1680)
        case .koboClaraColour: return CGSize(width: 1072, height: 1448)
        case .koboElipsa2E:    return CGSize(width: 1404, height: 1872)
        case .koboSage:        return CGSize(width: 1440, height: 1920)
        case .koboLibra2:      return CGSize(width: 1264, height: 1680)

        // Boox
        case .booxTabUltraCPro: return CGSize(width: 1860, height: 2480)
        case .booxNoteAir3C:    return CGSize(width: 1860, height: 2480)
        case .booxPage:         return CGSize(width: 1264, height: 1680)
        case .booxPalma:        return CGSize(width: 824,  height: 1648)
        }
    }

    /// Per-page slot resolution when the device displays two pages side-by-side in landscape.
    /// Landscape rotates the screen: the longer dimension becomes the width.
    /// Each page occupies exactly half that width.
    ///
    /// Only large-screen Kindles suppress letterboxing enough to make
    /// the per-slot pre-fit worthwhile; smaller devices (7") use the
    /// standard portrait resolution and let Kindle scale them.
    var landscapeHalfSlotResolution: CGSize? {
        switch self {
        // Scribe Colorsoft 11": landscape = 2640 × 1980, each slot = 1320 × 1980
        case .scribeColorsoft: return CGSize(width: 1320, height: 1980)
        // Kindle Scribe 1st gen 10.2": landscape = 2480 × 1860, each slot = 1240 × 1860
        case .scribe:          return CGSize(width: 1240, height: 1860)
        default: return nil
        }
    }
}

// MARK: - Settings Models

// âœ… NEW: File Split Modes
enum FileSizeSplitMode: String, CaseIterable, Codable, Identifiable {
    case none = "No Limit (One File)"
    case email = "Email Safe (23 MB)"
    case app = "App Share Safe (47 MB)"
    case web = "Web Safe (195 MB)"
    
    var id: String { rawValue }
    
    // The limit in Bytes
    var limit: Int64 {
        switch self {
        case .none: return Int64.max
        case .email: return 23 * 1024 * 1024
        case .app: return 47 * 1024 * 1024
        case .web: return 195 * 1024 * 1024
        }
    }
    
    var description: String {
        switch self {
        case .none: return "Keep as one large file."
        case .email: return "Splits for 'Send-to-Kindle' Email."
        case .app: return "Splits for Kindle App sharing."
        case .web: return "Splits for 'Send-to-Kindle' Web (195MB)."
        }
    }
}

// âœ… NEW: Panel Generation Strategy REMOVED

// âœ… NEW: App Text Size Preference
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


// âœ… NEW: Panel Editor Presentation Mode
enum PanelEditorPresentationMode: String, CaseIterable, Codable, Identifiable {
    case sheet = "Windowed (Sheet)"
    case fullScreen = "Full Screen"
    
    var id: String { rawValue }
}

enum AIVendor: String, CaseIterable, Codable, Identifiable {
    case openRouter = "OpenRouter (All Models)"
    case openAI = "OpenAI (GPT-4o)"
    case anthropic = "Anthropic (Claude 3.5)"
    case gemini = "Google (Gemini 2.5)"
    
    var id: String { rawValue }
}

enum CoverBadgePlacement: String, Codable, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"
    case center = "Center"
    case hidden = "Hidden"
    
    var id: String { rawValue }
}

struct ConversionSettings: Codable, Equatable, Sendable {
    var outputFormat: OutputFormat = .epub
    var compressionQuality: CompressionPreset = .balanced
    var optimizeForDevice: Bool = true
    var targetDeviceProfile: TargetDeviceProfile = .original // âœ… NEW: E-Ink Target
    var mangaMode: Bool = false
    var enablePanelSplit: Bool = false
    var splitWebtoon: Bool = false // âœ… Added for Smart Slicing
    var splitSpreads: Bool = false // âœ… NEW: Landscape Double-Page Split for E-Ink
    var trimMargins: Bool = false
    var splitMode: FileSizeSplitMode = .none
    var enableBackgroundQueue: Bool = true
    var textSize: AppTextSize = .medium
    var panelEditorMode: PanelEditorPresentationMode = .sheet
    var bindingMarginOffset: Int = 0             // âœ… NEW: Asymmetric Margin Padding
    var bindingMarginSide: BindingMarginSide = .none // âœ… NEW: Asymmetric Margin Side
    
    // âœ… NEW: Omnibus Settings
    var omnibusSplitThresholdMB: Int = 200
    var omnibusBadgePlacement: CoverBadgePlacement = .bottomRight
    
    // Debugger Visibility
    var showEditorDebug: Bool = false
    
    // AI Integrations
    var aiVendor: AIVendor = .openRouter
    
    // Metadata Strategy
    var deepFetchComicVineIssues: Bool = false
    
    // Export pipeline â€” the canonical source of truth for which converter to use.
    // .standard  â†’ plain EPUB/PDF, no panel zoom metadata, cloud-safe
    // .proPanel  â†’ KF8 EPUB (Kindle Region Magnification Panels) for sideloading/previewer
    var outputPipeline: OutputPipeline = .standard
    
    // Legacy computed property â€” kept for compatibility with existing code.
    // Do NOT set this directly; change outputPipeline instead.
    var isGuidedView: Bool { outputPipeline == .proPanel }
    
    // âœ… Keychain Integration
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
    
    var openRouterAPIKey: String {
        get {
            if let data = KeychainHelper.standard.read(service: "com.antigravity.InksyncPro", account: "openRouterAPIKey"),
               let key = String(data: data, encoding: .utf8) {
                return key
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                KeychainHelper.standard.delete(service: "com.antigravity.InksyncPro", account: "openRouterAPIKey")
            } else {
                let data = Data(newValue.utf8)
                KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "openRouterAPIKey")
            }
        }
    }
    
    var anthropicAPIKey: String {
        get {
            if let data = KeychainHelper.standard.read(service: "com.antigravity.InksyncPro", account: "anthropicAPIKey"),
               let key = String(data: data, encoding: .utf8) {
                return key
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                KeychainHelper.standard.delete(service: "com.antigravity.InksyncPro", account: "anthropicAPIKey")
            } else {
                let data = Data(newValue.utf8)
                KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "anthropicAPIKey")
            }
        }
    }
    
    var openAIAPIKey: String {
        get {
            if let data = KeychainHelper.standard.read(service: "com.antigravity.InksyncPro", account: "openAIAPIKey"),
               let key = String(data: data, encoding: .utf8) {
                return key
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                KeychainHelper.standard.delete(service: "com.antigravity.InksyncPro", account: "openAIAPIKey")
            } else {
                let data = Data(newValue.utf8)
                KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "openAIAPIKey")
            }
        }
    }
    
    var geminiAPIKey: String {
        get {
            if let data = KeychainHelper.standard.read(service: "com.antigravity.InksyncPro", account: "geminiAPIKey"),
               let key = String(data: data, encoding: .utf8) {
                return key
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                KeychainHelper.standard.delete(service: "com.antigravity.InksyncPro", account: "geminiAPIKey")
            } else {
                let data = Data(newValue.utf8)
                KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "geminiAPIKey")
            }
        }
    }
    
    var epubSettings: EPUBSettings = EPUBSettings()
    var imageEnhancement: ImageEnhancementSettings = ImageEnhancementSettings()
    
    // Custom Codable implementation to handle migration
                            
    enum CodingKeys: String, CodingKey {
        case outputFormat, compressionQuality, optimizeForDevice, targetDeviceProfile, mangaMode, enablePanelSplit, splitWebtoon, splitSpreads, trimMargins, splitMode, enableBackgroundQueue, epubSettings, imageEnhancement, textSize, panelEditorMode, bindingMarginOffset, bindingMarginSide, showEditorDebug
        case aiVendor         // New AI Vendor choice
        case outputPipeline   // New canonical export mode
        case isGuidedView     // Legacy â€” read-only for migration
        case comicVineAPIKey  // Legacy API key migration only
        case openRouterAPIKey // Legacy migration only
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputFormat = try container.decode(OutputFormat.self, forKey: .outputFormat)
        compressionQuality = try container.decode(CompressionPreset.self, forKey: .compressionQuality)
        optimizeForDevice = try container.decode(Bool.self, forKey: .optimizeForDevice)
        targetDeviceProfile = try container.decodeIfPresent(TargetDeviceProfile.self, forKey: .targetDeviceProfile) ?? .original
        mangaMode = try container.decode(Bool.self, forKey: .mangaMode)
        enablePanelSplit = try container.decode(Bool.self, forKey: .enablePanelSplit)
        splitWebtoon = try container.decodeIfPresent(Bool.self, forKey: .splitWebtoon) ?? false
        splitSpreads = try container.decodeIfPresent(Bool.self, forKey: .splitSpreads) ?? false
        trimMargins = try container.decodeIfPresent(Bool.self, forKey: .trimMargins) ?? false
        splitMode = try container.decode(FileSizeSplitMode.self, forKey: .splitMode)
        enableBackgroundQueue = try container.decodeIfPresent(Bool.self, forKey: .enableBackgroundQueue) ?? true
        epubSettings = try container.decode(EPUBSettings.self, forKey: .epubSettings)
        imageEnhancement = try container.decode(ImageEnhancementSettings.self, forKey: .imageEnhancement)
        textSize = try container.decodeIfPresent(AppTextSize.self, forKey: .textSize) ?? .medium
        panelEditorMode = try container.decodeIfPresent(PanelEditorPresentationMode.self, forKey: .panelEditorMode) ?? .sheet
        bindingMarginOffset = try container.decodeIfPresent(Int.self, forKey: .bindingMarginOffset) ?? 0
        bindingMarginSide = try container.decodeIfPresent(BindingMarginSide.self, forKey: .bindingMarginSide) ?? .none
        showEditorDebug = try container.decodeIfPresent(Bool.self, forKey: .showEditorDebug) ?? false
        aiVendor = try container.decodeIfPresent(AIVendor.self, forKey: .aiVendor) ?? .openRouter
        
        // Migration: if new outputPipeline key is present, decode it.
        // Otherwise fall back to the legacy isGuidedView bool to preserve user's previous setting.
        if let pipeline = try? container.decodeIfPresent(OutputPipeline.self, forKey: .outputPipeline) {
            // Handle deprecated proPanelEPUB or AZW3 from old state by coalescing to proPanel
            if pipeline.rawValue == "Pro Panel (Sideload Only)" || pipeline.rawValue == "Pro Panel EPUB (Previewer)" {
                outputPipeline = .proPanel
            } else {
                outputPipeline = pipeline
            }
        } else {
            let legacyGuided = (try? container.decodeIfPresent(Bool.self, forKey: .isGuidedView)) ?? false
            outputPipeline = legacyGuided ? .proPanel : .standard
        }
        
        // Legacy API key migration
        if let legacyKey = try? container.decodeIfPresent(String.self, forKey: .comicVineAPIKey), !legacyKey.isEmpty {
            print("ðŸ” Migrating Legacy API Key to Keychain...")
            let data = Data(legacyKey.utf8)
            KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "comicVineAPIKey")
        }
        
        if let legacyRouterKey = try? container.decodeIfPresent(String.self, forKey: .openRouterAPIKey), !legacyRouterKey.isEmpty {
            let data = Data(legacyRouterKey.utf8)
            KeychainHelper.standard.save(data, service: "com.antigravity.InksyncPro", account: "openRouterAPIKey")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outputFormat, forKey: .outputFormat)
        try container.encode(compressionQuality, forKey: .compressionQuality)
        try container.encode(optimizeForDevice, forKey: .optimizeForDevice)
        try container.encode(targetDeviceProfile, forKey: .targetDeviceProfile)
        try container.encode(mangaMode, forKey: .mangaMode)
        try container.encode(enablePanelSplit, forKey: .enablePanelSplit)
        try container.encode(splitWebtoon, forKey: .splitWebtoon)
        try container.encode(splitSpreads, forKey: .splitSpreads)
        try container.encode(trimMargins, forKey: .trimMargins)
        try container.encode(splitMode, forKey: .splitMode)
        try container.encode(enableBackgroundQueue, forKey: .enableBackgroundQueue)
        try container.encode(epubSettings, forKey: .epubSettings)
        try container.encode(imageEnhancement, forKey: .imageEnhancement)
        try container.encode(textSize, forKey: .textSize)
        try container.encode(panelEditorMode, forKey: .panelEditorMode)
        try container.encode(bindingMarginOffset, forKey: .bindingMarginOffset)
        try container.encode(bindingMarginSide, forKey: .bindingMarginSide)
        try container.encode(outputPipeline, forKey: .outputPipeline)
        try container.encode(showEditorDebug, forKey: .showEditorDebug)
        // comicVineAPIKey is intentionally not encoded (moved to Keychain)
        // isGuidedView is intentionally not encoded (computed from outputPipeline)
    }
}

struct EPUBSettings: Codable, Equatable, Sendable {
    enum ReadingDirection: String, Codable {
        case ltr = "ltr"
        case rtl = "rtl"
    }
    
    // âœ… Export Format (EPUB vs CBZ for Guided View) REMOVED - Enforcing EPUB/Virtual
    
    var panelDetectionMode: PanelExtractor.ExtractionMode = .automatic
    var includeTableOfContents: Bool = false
    var splitPanels: Bool = false
    var includeFullPage: Bool = true
    var panelDetectionConfidence: Double = 0.6
    var readingDirection: ReadingDirection = .ltr
}

struct ImageEnhancementSettings: Codable, Equatable, Sendable {
    var grayscale: Bool = false
    var autoContrast: Bool = false
    var invertColors: Bool = false
    var brightness: Double = 0.0
    var sharpness: Double = 0.0
    var vibrance: Double = 0.0
    // âœ… KCC: Gamma Correction (Crucial for E-Ink to prevent black crush)
    var gamma: Double = 1.0 
    // âœ… Pro E-Ink Enhancements
    var reduceMoire: Bool = false
    var ditheringEnabled: Bool = false
}

enum BindingMarginSide: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case left = "Left"
    case right = "Right"
    case alternating = "Alternating (Odd/Even)"
    
    var id: String { rawValue }
}

// MARK: - Output Pipeline
/// Determines the conversion pipeline used when exporting a comic.
/// - `.standard` : Plain EPUB/PDF. No panel zoom metadata. Safe for cloud sync.
/// - `.proPanel` : KF8 EPUB with Region Magnification panels.
enum OutputPipeline: String, CaseIterable, Codable, Identifiable {
    case standard = "Standard (Cloud-Safe)"
    case proPanel = "Pro Panel (Guided View)"

    var id: String { rawValue }
}

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case epub = "EPUB (Kindle)"
    case pdf = "PDF"
    case cbz = "CBZ"
    case kfxPackage = "KFX-Ready Package (.inksync)"
    
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .epub: return "book.fill"
        case .pdf: return "doc.text.fill"
        case .cbz: return "archivebox.fill"
        case .kfxPackage: return "square.and.arrow.up.on.square"
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

struct ConversionPreset: Identifiable, Codable, Sendable {
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

// MARK: - Global Alert
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Editor Models (Precision Canvas)

struct PageModel: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var pageIndex: Int
    var panels: [NormalizedRect] = []
    var proposedPanels: [NormalizedRect] = [] // AI Suggestions
    
    // âœ… NEW: Explicit Coordinate System Tracking
    // This allows us to trust "Known Good" panels (e.g. from Auto-Scan) and only run heuristics on Legacy/Unknown data.
    var coordinateSystem: PageCoordinateSystem = .unknown 
    
    // Explicit Codable Synthesis & Initializers
    init(id: UUID = UUID(), pageIndex: Int, panels: [NormalizedRect] = [], proposedPanels: [NormalizedRect] = [], coordinateSystem: PageCoordinateSystem = .unknown) {
        self.id = id
        self.pageIndex = pageIndex
        self.panels = panels
        self.proposedPanels = proposedPanels
        self.coordinateSystem = coordinateSystem
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        self.panels = try container.decode([NormalizedRect].self, forKey: .panels)
        self.proposedPanels = try container.decode([NormalizedRect].self, forKey: .proposedPanels)
        self.coordinateSystem = try container.decode(PageCoordinateSystem.self, forKey: .coordinateSystem)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(panels, forKey: .panels)
        try container.encode(proposedPanels, forKey: .proposedPanels)
        try container.encode(coordinateSystem, forKey: .coordinateSystem)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, pageIndex, panels, proposedPanels, coordinateSystem
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pageIndex)
        hasher.combine(panels)
        hasher.combine(proposedPanels)
        hasher.combine(coordinateSystem)
    }
    
    static func == (lhs: PageModel, rhs: PageModel) -> Bool {
        return lhs.id == rhs.id && lhs.pageIndex == rhs.pageIndex && lhs.panels == rhs.panels && lhs.proposedPanels == rhs.proposedPanels && lhs.coordinateSystem == rhs.coordinateSystem
    }
}

// âœ… Coordinate System Helper
enum PageCoordinateSystem: String, Codable, Equatable, Hashable {
    case unknown = "check_required" // Legacy files, needs heuristic
    case normalized = "normalized_0_1000" // Known Good (New Scan, Validated)
    case pixels = "pixels" // Raw pixels (needs conversion)
}

// MARK: - SwiftData Migration Models (Phase 5)
// These prefixes (SD) allow incremental lazy-loading adoption without instantaneously shattering the 190+ view dependency injections bound to the legacy struct.
@Model final class SDConvertedPDF: Identifiable, Hashable {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: URL
    var parentFolderID: UUID?
    
    // Core Data Sync fields
    var dataSyncHash: String?
    var lastModified: Date
    var pageCount: Int
    var fileSize: Int64
    var metadata: PDFMetadata
    var collectionId: UUID?
    var isFavorite: Bool
    var isPrivate: Bool
    
    @Attribute(.externalStorage)
    var coverImageData: Data?
    
    var contentType: ContentType
    var chapters: [Chapter]
    var addedByMode: AppUIMode
    
    // Unified Reader Properties
    var contentKind: ContentKind
    var documentSubtype: DocumentSubtype
    var isOnDevice: Bool
    var lastTransferFailed: Bool
    var lastOutputFormat: OutputFormat?
    var lastConversionDate: Date?
    var panelConfidenceScore: Double?
    
    @Transient var fileExtensionString: String {
        return url.pathExtension.uppercased()
    }
    
    @Transient var formattedSize: String {
        let mb = Double(fileSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    init(id: UUID = UUID(), name: String, url: URL, pageCount: Int, fileSize: Int64, metadata: PDFMetadata, collectionId: UUID? = nil, isFavorite: Bool = false, isPrivate: Bool = false, coverImageData: Data? = nil, contentType: ContentType = .comic, chapters: [Chapter] = [], addedByMode: AppUIMode = .pro) {
        self.id = id
        self.name = name
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.collectionId = collectionId
        self.isFavorite = isFavorite
        self.isPrivate = isPrivate
        self.coverImageData = coverImageData
        self.contentType = contentType
        self.chapters = chapters
        self.addedByMode = addedByMode
        
        self.lastModified = Date()
        self.contentKind = .comic
        self.documentSubtype = .unknown
        self.isOnDevice = false
        self.lastTransferFailed = false
    }
    
    // Bridge to Legacy Architecture during Phase 2 transitions
    func toDTO() -> ConvertedPDF {
        var pdf = ConvertedPDF(id: self.id, name: self.name, url: self.url, pageCount: self.pageCount, fileSize: self.fileSize, metadata: self.metadata, collectionId: self.collectionId, isFavorite: self.isFavorite, isPrivate: self.isPrivate, coverImageData: nil)
        pdf.contentType = self.contentType
        pdf.chapters = self.chapters
        pdf.addedByMode = self.addedByMode
        pdf.contentKind = self.contentKind
        pdf.documentSubtype = self.documentSubtype
        pdf.isOnDevice = self.isOnDevice
        pdf.lastTransferFailed = self.lastTransferFailed
        pdf.lastOutputFormat = self.lastOutputFormat
        pdf.lastConversionDate = self.lastConversionDate
        pdf.panelConfidenceScore = self.panelConfidenceScore
        return pdf
    }
}

@Model final class SDPDFCollection: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var color: String
    var creationDate: Date
    var explicitCoverFileID: UUID?
    
    init(id: UUID, name: String, icon: String, color: String, creationDate: Date, explicitCoverFileID: UUID? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.creationDate = creationDate
        self.explicitCoverFileID = explicitCoverFileID
    }
    
    func toDTO() -> PDFCollection {
        PDFCollection(id: self.id, name: self.name, icon: self.icon, color: self.color, creationDate: self.creationDate, explicitCoverFileID: self.explicitCoverFileID)
    }
}

