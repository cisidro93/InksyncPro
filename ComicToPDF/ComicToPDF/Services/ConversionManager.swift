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
    // Fallback since I haven't viewed the class definition yet.
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
    
    // NEW: Panel Features
    var enablePanelSplit: Bool = false
    // mangaMode is already defined above at line 125, removing duplicate.
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

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case pdf = "PDF"
    case epub = "EPUB"
    case both = "Both"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .epub: return "book.fill"
        case .both: return "doc.on.doc.fill"
        }
    }
    
    var description: String {
        switch self {
        case .pdf: return "PDF (Kindle, universal)"
        case .epub: return "EPUB (Apple Books, Kobo, etc.)"
        case .both: return "PDF + EPUB (maximum compatibility)"
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
    
    // NEW: Panel View Settings
    var enablePanelView: Bool = false
    var panelDetectionMode: PanelDetectionMode = .automatic
    var panelMinSize: Double = 0.05  // Minimum panel size (5% of page)
    var panelMaxSize: Double = 0.90  // Maximum panel size (90% of page)
    
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

// ============================================================================
// MARK: - BACKGROUND TASKS
// ============================================================================

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

// ============================================================================
// MARK: - CONVERSION MANAGER
// ============================================================================

@MainActor
class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var conversionQueue: [ConversionQueueItem] = []
    @Published var isConverting = false
    @Published var progress: Double = 0.0
    @Published var alertMessage: String?
    
    // ✅ ADD THIS NEW PROPERTY
    @Published var processingStatus: String = ""
    
    // MARK: - Panel Editor State
    @Published var showingPanelEditor = false
    @Published var currentPanelSession: PanelEditSession?
    @Published var panelEditorCompletion: ((PanelEditSession?) -> Void)?
    @Published var collections: [PDFCollection] = []
    

    @Published var kindleDevices: [KindleDevice] = []
    @Published var conversionSettings = ConversionSettings()
    @Published var sendHistory: [SendHistoryRecord] = []
    @Published var conversionPresets: [ConversionPreset] = []
    
    // Thumbnail cache
    // Thumbnail cache - using NSCache for automatic memory management

    // Incremental save
    private var saveTimer: Timer?
    private var needsSave = false
    @Published var searchText: String = ""
    @Published var filterFavoritesOnly: Bool = false
    @Published var filterCollection: UUID? = nil
    @Published var sortOption: SortOption = .name
    
    @Published var activeTasks: [BackgroundTask] = []
    
    // Performance
    lazy var thumbnailCache = NSCache<NSString, UIImage>()

    private let fileManager = FileManager.default
    
    // Helper for memory mapped reading
    func readFileMapped(at url: URL) throws -> Data {
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    
    // MARK: - Background Processing
    
    func splitFileInBackground(pdf: ConvertedPDF, maxSizeMB: Double) {
        let taskInfo = BackgroundTask(description: "Splitting \(pdf.name)...")
        self.activeTasks.append(taskInfo)
        
        Task {
            do {
                let parts: [URL]
                if pdf.url.pathExtension.lowercased() == "epub" {
                     // Use new ComicEPUBProcessor for robust splitting
                     // Convert Double MB to Int MB
                     parts = try ComicEPUBProcessor.splitEPUB(pdf.url, maxSizeMB: Int(maxSizeMB))
                     taskInfo.progress = 1.0
                } else {
                     parts = try await performSplit(pdf: pdf, maxSizeMB: maxSizeMB) { p in
                         taskInfo.progress = p
                     }
                }
                
                await MainActor.run {
                    for partURL in parts { self.addToLibrary(partURL) }
                    
                    if let index = self.activeTasks.firstIndex(where: { $0.id == taskInfo.id }) {
                        self.activeTasks.remove(at: index)
                    }
                    
                    // Optional: Notification could be implemented here (e.g. UNUserNotificationCenter)
                    print("✅ Split complete. Created \(parts.count) parts.")
                }
            } catch {
                await MainActor.run {
                    if let index = self.activeTasks.firstIndex(where: { $0.id == taskInfo.id }) {
                        self.activeTasks.remove(at: index)
                    }
                    print("❌ Split failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Split Logic (Moved from PDFActionViews)
    
    private func performSplit(pdf: ConvertedPDF, maxSizeMB: Double, onProgress: @escaping (Double) -> Void) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let document = PDFDocument(url: pdf.url) else {
                        throw NSError(domain: "SplitPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF"])
                    }
                    
                    let pageCount = document.pageCount
                    let maxBytes = Int(maxSizeMB) * 1024 * 1024
                    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let outputDir = documentsPath.appendingPathComponent("ConvertedPDFs", isDirectory: true)
                    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                    
                    var parts: [URL] = []
                    var currentPart = PDFDocument()
                    var currentPartIndex = 1
                    var pagesInCurrentPart = 0
                    let baseName = pdf.name
                    
                    let avgPageSize = pdf.fileSize / Int64(max(pageCount, 1))
                    let pagesPerPart = max(1, Int(Int64(maxBytes) / max(avgPageSize, 1)))
                    
                    for i in 0..<pageCount {
                        autoreleasepool {
                            if let page = document.page(at: i) {
                                currentPart.insert(page, at: pagesInCurrentPart)
                                pagesInCurrentPart += 1
                            }
                        }
                        
                        // Memory cleanup
                        if i % 10 == 0 { await Task.yield() }
                        
                        if pagesInCurrentPart >= pagesPerPart || i == pageCount - 1 {
                            let partURL = outputDir.appendingPathComponent("\(baseName)_part\(currentPartIndex).pdf")
                            if FileManager.default.fileExists(atPath: partURL.path) { try? FileManager.default.removeItem(at: partURL) }
                            if currentPart.write(to: partURL) { parts.append(partURL) }
                            currentPart = PDFDocument()
                            pagesInCurrentPart = 0
                            currentPartIndex += 1
                        }
                        
                        await MainActor.run { onProgress(Double(i + 1) / Double(pageCount)) }
                    }
                    
                    continuation.resume(returning: parts)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Legacy split logic removed to prevent horizontal stripping.
    // Use ComicEPUBProcessor.splitEPUB() instead.
    
    var filteredPDFs: [ConvertedPDF] {
        var result = convertedPDFs
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.metadata.title.localizedCaseInsensitiveContains(searchText) || $0.metadata.series.localizedCaseInsensitiveContains(searchText) }
        }
        if filterFavoritesOnly {
            result = result.filter { $0.isFavorite }
        }
        if let collectionId = filterCollection {
            result = result.filter { $0.collectionId == collectionId }
        }
        switch sortOption {
        case .dateAdded: result.sort { $0.dateAdded > $1.dateAdded }
        case .name: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: result.sort { $0.fileSize > $1.fileSize }
        case .pageCount: result.sort { $0.pageCount > $1.pageCount }
        }
        return result
    }
    
    var kindleEmail: String {
        get { kindleDevices.first(where: { $0.isDefault })?.email ?? kindleDevices.first?.email ?? "" }
        set {
            if kindleDevices.isEmpty {
                kindleDevices.append(KindleDevice(name: "My Kindle", email: newValue, isDefault: true))
            } else if let index = kindleDevices.firstIndex(where: { $0.isDefault }) {
                kindleDevices[index].email = newValue
            }
            saveKindleDevices()
        }
    }
    

    private let outputDirectory: URL
    
    init() {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputDirectory = documentsPath.appendingPathComponent("ConvertedPDFs", isDirectory: true)
        try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        loadSavedData()
    }
    
    func convertToPDF(from sourceURL: URL, customName: String? = nil, settings: ConversionSettings? = nil, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        let config = settings ?? conversionSettings
        let ext = sourceURL.pathExtension.lowercased()
        
        // Special handling for EPUB using refined converter
        // Special handling for EPUB using refined converter
        if ext == "epub" {
            return try await withCheckedThrowingContinuation { continuation in
                // Use the new user-provided converter for reliable strip reconstruction
                let converter = EPUBtoPDFConverter()
                converter.convertEPUBtoPDF(sourceURL) { result in
                    progressHandler(1.0)
                    
                    switch result {
                    case .success(let pdfURL):
                        // Move to output directory
                        let outputName = customName ?? sourceURL.deletingPathExtension().lastPathComponent
                        let finalURL = self.outputDirectory.appendingPathComponent("\(outputName).pdf")
                        do {
                            if FileManager.default.fileExists(atPath: finalURL.path) {
                                try FileManager.default.removeItem(at: finalURL)
                            }
                            try FileManager.default.moveItem(at: pdfURL, to: finalURL)
                            continuation.resume(returning: finalURL)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                        
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        
        var images = try await extractImages(from: sourceURL) { progress in
            progressHandler(progress * 0.4)
        }
        guard !images.isEmpty else { throw ConversionError.noImagesFound }
        if config.mangaMode { images.reverse() }
        
        let scale: Double
        let jpegQuality: Double
        if config.compressionQuality == .custom {
            scale = config.customScale
            jpegQuality = config.customJpegQuality
        } else {
            let values = config.compressionQuality.values
            scale = values.scale
            jpegQuality = values.quality
        }
        
        var targetSize: CGSize? = nil
        if config.optimizeForDevice { targetSize = config.targetDevice.resolution }
        
        let processedImages = try await processImages(images, scale: scale, jpegQuality: jpegQuality, enhancement: config.imageEnhancement, targetSize: targetSize) { progress in
            progressHandler(0.4 + progress * 0.4)
        }
        
        let outputName = customName ?? sourceURL.deletingPathExtension().lastPathComponent
        let pdfURL = try await createPDF(from: processedImages, named: outputName, jpegQuality: jpegQuality) { progress in
            progressHandler(0.8 + progress * 0.2)
        }
        return pdfURL
    }
    
    // MARK: - Universal Conversion
    
    func convertToFormat(_ format: OutputFormat, from sourceURL: URL, settings: ConversionSettings? = nil, progressHandler: @escaping (Double) -> Void) async throws -> [URL] {
        let config = settings ?? conversionSettings
        var outputURLs: [URL] = []
        
        switch format {
        case .pdf:
            let url = try await convertToPDF(from: sourceURL, settings: config, progressHandler: progressHandler)
            outputURLs.append(url)
            addToLibrary(url)
            
        case .epub:
            let (urls, pageCount) = try await convertToEPUB(from: sourceURL, settings: config, progressHandler: progressHandler)
            outputURLs.append(contentsOf: urls)
            for url in urls {
                addToLibrary(url, explicitPageCount: pageCount)
            }
            
        case .both:
            // Split progress: 50% for PDF, 50% for EPUB
            let pdfURL = try await convertToPDF(from: sourceURL, settings: config) { p in
                progressHandler(p * 0.5)
            }
            outputURLs.append(pdfURL)
            addToLibrary(pdfURL)
            
            let (urls, pageCount) = try await convertToEPUB(from: sourceURL, settings: config) { p in
                progressHandler(0.5 + p * 0.5)
            }
            outputURLs.append(contentsOf: urls)
            for url in urls {
                addToLibrary(url, explicitPageCount: pageCount)
            }
        }
        
        return outputURLs
    }
    
    // ✅ NEW HELPER: Handles the Panel Editor UI flow with improved error checking
    private func performPanelReview(sourceEPUB: URL, settings: EPUBSettings) async throws -> (EPUBPanelManifest?, Int) {
        
        await MainActor.run { self.processingStatus = "Preparing Panel Editor..." }
        
        // 1. Create a clean session directory
        let sessionID = UUID().uuidString
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("EditorSession_\(sessionID)")
        try? FileManager.default.removeItem(at: sessionDir)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        
        // 2. Extract images to this directory for editing
        let fileDir = sessionDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        
        print("📂 Panel Editor Session Dir: \(sessionDir.path)")
        
        do {
            try FileManager.default.unzipItem(at: sourceEPUB, to: fileDir)
        } catch {
            print("❌ Failed to unzip EPUB for review: \(error)")
            try? FileManager.default.removeItem(at: sessionDir)
            throw error
        }
        
        // 3. Find images
        var foundImageURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: fileDir, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if ["jpg", "jpeg", "png", "webp"].contains(fileURL.pathExtension.lowercased()) {
                    foundImageURLs.append(fileURL)
                }
            }
        }
        foundImageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        guard !foundImageURLs.isEmpty else {
            print("⚠️ No images found in EPUB for panel review.")
            try? FileManager.default.removeItem(at: sessionDir)
            return (nil, 0)
        }
        
        // 4. Run Auto-Detection and Validate Images
        var pages: [PanelEditSession.PageEditData] = []
        let detectionMode: PanelExtractor.ExtractionMode = {
            switch settings.panelDetectionMode {
            case .grid2x2: return .grid(rows: 2, columns: 2)
            case .grid3x3: return .grid(rows: 3, columns: 3)
            case .grid2x3: return .grid(rows: 2, columns: 3)
            default: return .automatic
            }
        }()
        
        for (index, imageURL) in foundImageURLs.enumerated() {
            await MainActor.run { self.processingStatus = "Detecting Panels: Page \(index + 1)/\(foundImageURLs.count)" }
            
            do {
                guard FileManager.default.isReadableFile(atPath: imageURL.path) else { continue }
                
                let data = try Data(contentsOf: imageURL)
                if let image = UIImage(data: data) {
                     let panels = try? await PanelExtractor.extractPanels(from: image, mode: detectionMode)
                     let editable = (panels ?? []).enumerated().map { idx, p in EditablePanel(from: p, order: idx + 1) }
                     
                     pages.append(PanelEditSession.PageEditData(
                         pageNumber: index + 1,
                         imageURL: imageURL,
                         panels: editable
                     ))
                }
            } catch {
                print("❌ Failed to verify image for \(imageURL.lastPathComponent): \(error)")
            }
        }
        
        guard !pages.isEmpty else {
            print("⚠️ No valid pages could be prepared for panel review.")
            try? FileManager.default.removeItem(at: sessionDir)
            return (nil, foundImageURLs.count)
        }
        
        // 5. Show UI and Wait
        let session = PanelEditSession(pages: pages, readingDirection: settings.readingDirection, sessionTempDirectory: sessionDir)
        
        print("🚀 Presenting Panel Editor UI...")
        
        // SUSPEND execution and wait for the UI to signal completion
        let editedSession: PanelEditSession? = await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.currentPanelSession = session
                self.showingPanelEditor = true
                
                // Define the completion handler that the UI will call
                self.panelEditorCompletion = { result in
                    print("✅ Panel Editor finished (Cancelled: \(result == nil)).")
                    self.showingPanelEditor = false
                    self.currentPanelSession = nil
                    self.panelEditorCompletion = nil
                    continuation.resume(returning: result)
                }
            }
        }
        
        // 6. Handle Cancellation or Completion
        guard let validSession = editedSession else {
            print("⚠️ Panel Editor Cancelled. Proceeding without panel view.")
            try? FileManager.default.removeItem(at: sessionDir)
            return (nil, foundImageURLs.count)
        }
        
        // 7. Process the Valid Session (Generate Manifest)
        await MainActor.run { self.processingStatus = "Finalizing Panels..." }
        
        var allPagePanels: [EPUBPanelManifest.PagePanels] = []
        for page in validSession.pages {
            if let data = try? Data(contentsOf: page.imageURL), let image = UIImage(data: data), let cgImage = image.cgImage {
                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                let panels = page.panels.sorted(by: { $0.order < $1.order }).map { $0.toNormalizedRegion(imageSize: imageSize) }
                
                allPagePanels.append(EPUBPanelManifest.PagePanels(
                    pageNumber: page.pageNumber,
                    imageFile: "page\(page.pageNumber).jpg",
                    panels: panels
                ))
            }
        }
        
        // Clean up temp session files
        print("🧹 Cleaning up session directory: \(sessionDir.path)")
        try? FileManager.default.removeItem(at: sessionDir)
        
        let manifest = EPUBPanelManifest(
            version: "1.0",
            readingDirection: validSession.readingDirection == .rightToLeft ? "rtl" : "ltr",
            pages: allPagePanels
        )
        
        return (manifest, foundImageURLs.count)
    }
    
    func convertToEPUB(from sourceURL: URL, settings: ConversionSettings? = nil, progressHandler: @escaping (Double) -> Void) async throws -> ([URL], Int) {
        let config = settings ?? conversionSettings
        let outputName = sourceURL.deletingPathExtension().lastPathComponent
        
        // 1. Generate the "Raw" EPUB first (using existing converters)
        var initialEPUB: URL
        var pageCount = 0
        
        let isPDF = sourceURL.pathExtension.lowercased() == "pdf"
        
        if isPDF {
            let tempOutput = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("\(outputName).epub")
            try? FileManager.default.createDirectory(at: tempOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            let converter = PDFToEPUBConverter()
            var options = PDFToEPUBConverter.ConversionOptions.default
            
            var scale: Double = 1.0
            if config.compressionQuality == .custom {
                 options.imageQuality = config.customJpegQuality
                 scale = config.customScale
            } else {
                 options.imageQuality = config.compressionQuality.values.quality
                 scale = config.compressionQuality.values.scale
            }
            options.maxImageWidth = 1600 * CGFloat(scale)
            options.maxImageHeight = 2400 * CGFloat(scale)
            options.title = outputName
            
            let (url, count) = try await converter.convert(pdfURL: sourceURL, to: self.outputDirectory.appendingPathComponent("\(outputName).epub"), options: options) { p in
                // Only go up to 50% progress if we might do panel detection
                let maxProgress = config.epubSettings.enablePanelView ? 0.5 : 1.0
                progressHandler(p.percentage * maxProgress)
            }
            initialEPUB = url
            pageCount = count
            
        } else {
            // CBZ/CBR path
            let jpegQuality = config.compressionQuality == .custom ? config.customJpegQuality : config.compressionQuality.values.quality
            let converter = CBZToEPUBConverter()
            initialEPUB = try await converter.convertCBZToEPUB(sourceURL, compressionQuality: jpegQuality)
            progressHandler(config.epubSettings.enablePanelView ? 0.5 : 1.0)
        }
        
        // 2. CHECK: Do we need Panel Detection?
        // FIX: We skipped the manual performPanelReview step to prevent UI blocking (Black Screen).
        // We now pass `precomputedManifest: nil`.
        // The EPUBMerger will handle auto-detection internally if enablePanelView is true.
        if config.epubSettings.enablePanelView {
            
            let metadata = PDFMetadata(title: outputName) // Basic metadata
            
            // We use EPUBMerger to "Merge" the single file with itself + new metadata
            // passing nil for precomputedManifest triggers auto-detection inside the merger
            let (finalURL, finalCount) = try await EPUBMerger.mergeEPUBs(
                sourceURLs: [initialEPUB],
                outputURL: self.outputDirectory.appendingPathComponent("\(outputName)_guided.epub"),
                metadata: metadata,
                settings: config.epubSettings,
                precomputedManifest: nil, // <<-- FORCE AUTO-DETECTION (No UI)
                onStatusUpdate: { status in
                    Task { @MainActor in self.processingStatus = status }
                }
            )
            
            // Cleanup the temp raw file
            try? FileManager.default.removeItem(at: initialEPUB)
            
            initialEPUB = finalURL
            pageCount = finalCount
        }
        
        // 3. Final Split Check (Existing Logic)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: initialEPUB.path)[.size] as? Int64) ?? 0
        if fileSize > 190 * 1024 * 1024 {
             await MainActor.run { self.processingStatus = "Splitting large EPUB..." }
             let parts = try ComicEPUBProcessor.splitEPUB(initialEPUB, maxSizeMB: 190)
             try? FileManager.default.removeItem(at: initialEPUB)
             progressHandler(1.0)
             return (parts, pageCount)
        }
        
        progressHandler(1.0)
        return ([initialEPUB], pageCount)
    }

    

    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Create a unique temp directory for this extraction
                    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    // Unzip the archive
                    try FileManager.default.unzipItem(at: url, to: tempDir)
                    
                    let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
                    var imageURLs: [URL] = []
                    
                    // Recursive search for images
                    if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            if imageExtensions.contains(fileURL.pathExtension.lowercased()) {
                                // Skip MacOS metadata files
                                if !fileURL.lastPathComponent.hasPrefix("._") && !fileURL.path.contains("__MACOSX") {
                                    imageURLs.append(fileURL)
                                }
                            }
                        }
                    }
                    
                    // Sort alphabetically to maintain order
                    imageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    
                    continuation.resume(returning: imageURLs)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Changed from 'private' to 'internal' so PageManagerView can access it
    func extractImages(from url: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    try FileManager.default.unzipItem(at: url, to: tempDir)
                    
                    let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
                    var imageURLs: [URL] = []
                    if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            if imageExtensions.contains(fileURL.pathExtension.lowercased()) {
                                imageURLs.append(fileURL)
                            }
                        }
                    }
                    imageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    
                    var images: [UIImage] = []
                    for (index, imageURL) in imageURLs.enumerated() {
                        autoreleasepool {
                            if let image = UIImage(contentsOfFile: imageURL.path) { images.append(image) }
                        }
                        DispatchQueue.main.async { progressHandler(Double(index + 1) / Double(imageURLs.count)) }
                    }
                    continuation.resume(returning: images)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    
    private func processImages(_ images: [UIImage], scale: Double, jpegQuality: Double, enhancement: ImageEnhancementSettings, targetSize: CGSize?, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        // Capture safe values on MainActor
        let enableSplit = self.conversionSettings.enablePanelSplit
        let isMangaMode = self.conversionSettings.mangaMode
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var processedImages: [UIImage] = []
                let context = CIContext()
                
                for (index, image) in images.enumerated() {
                    autoreleasepool {
                        // NEW: Panel Splitting Logic
                        // Uses ImageProcessor to split spreads if enabled
                        let splitImages = ImageProcessor.processPage(image, splitSpreads: enableSplit, isManga: isMangaMode)
                        
                        for splitImage in splitImages {
                            var processed = splitImage
                        
                        if enhancement.enabled, let ciImage = CIImage(image: splitImage) {
                            var enhancedCI = ciImage
                            
                            if enhancement.brightness != 0 || enhancement.contrast != 1.0 {
                                if let filter = CIFilter(name: "CIColorControls") {
                                    filter.setValue(enhancedCI, forKey: kCIInputImageKey)
                                    filter.setValue(enhancement.brightness, forKey: kCIInputBrightnessKey)
                                    filter.setValue(enhancement.contrast, forKey: kCIInputContrastKey)
                                    filter.setValue(enhancement.saturation, forKey: kCIInputSaturationKey)
                                    if let output = filter.outputImage { enhancedCI = output }
                                }
                            }
                            
                            if enhancement.sharpness > 0 {
                                if let filter = CIFilter(name: "CISharpenLuminance") {
                                    filter.setValue(enhancedCI, forKey: kCIInputImageKey)
                                    filter.setValue(enhancement.sharpness * 2.0, forKey: kCIInputSharpnessKey)
                                    if let output = filter.outputImage { enhancedCI = output }
                                }
                            }
                            
                            if enhancement.grayscale {
                                if let filter = CIFilter(name: "CIPhotoEffectMono") {
                                    filter.setValue(enhancedCI, forKey: kCIInputImageKey)
                                    if let output = filter.outputImage { enhancedCI = output }
                                }
                            }
                            
                            if enhancement.invertColors {
                                if let filter = CIFilter(name: "CIColorInvert") {
                                    filter.setValue(enhancedCI, forKey: kCIInputImageKey)
                                    if let output = filter.outputImage { enhancedCI = output }
                                }
                            }
                            
                            if enhancement.autoContrast {
                                if let filter = CIFilter(name: "CIColorControls") {
                                    filter.setValue(enhancedCI, forKey: kCIInputImageKey)
                                    filter.setValue(1.1, forKey: kCIInputContrastKey)
                                    if let output = filter.outputImage { enhancedCI = output }
                                }
                            }
                            
                            if let cgImage = context.createCGImage(enhancedCI, from: enhancedCI.extent) {
                                processed = UIImage(cgImage: cgImage)
                            }
                        }
                        
                        var newSize = processed.size
                        if let target = targetSize {
                            let widthRatio = target.width / processed.size.width
                            let heightRatio = target.height / processed.size.height
                            let ratio = min(widthRatio, heightRatio, 1.0)
                            newSize = CGSize(width: processed.size.width * ratio, height: processed.size.height * ratio)
                        }
                        newSize = CGSize(width: (newSize.width * scale).rounded(), height: (newSize.height * scale).rounded())
                        
                        if newSize != processed.size {
                             let format = UIGraphicsImageRendererFormat()
                             format.scale = 1.0
                             format.opaque = true
                             let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
                             processed = renderer.image { _ in
                                 processed.draw(in: CGRect(origin: .zero, size: newSize))
                             }
                        }
                        
                        if jpegQuality < 1.0 || enhancement.enabled {
                            // Ensure final format is consistent and compressed
                            if let jpegData = processed.jpegData(compressionQuality: jpegQuality), let recompressed = UIImage(data: jpegData) {
                                processed = recompressed
                            }
                        }
                        processedImages.append(processed)
                        } // End split loop
                    }
                    DispatchQueue.main.async { progressHandler(Double(index + 1) / Double(images.count)) }
                }
                continuation.resume(returning: processedImages)
            }
        }
    }
    
    private func createPDF(from images: [UIImage], named name: String, jpegQuality: Double, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let pdfDocument = PDFDocument()
                for (index, image) in images.enumerated() {
                    autoreleasepool {
                        if let pdfPage = PDFPage(image: image) { pdfDocument.insert(pdfPage, at: index) }
                    }
                    DispatchQueue.main.async { progressHandler(Double(index + 1) / Double(images.count)) }
                }
                
                let sanitizedName = name.replacingOccurrences(of: "/", with: "-")
                var outputURL = self.outputDirectory.appendingPathComponent("\(sanitizedName).pdf")
                var counter = 1
                while FileManager.default.fileExists(atPath: outputURL.path) {
                    outputURL = self.outputDirectory.appendingPathComponent("\(sanitizedName)_\(counter).pdf")
                    counter += 1
                }
                
                if pdfDocument.write(to: outputURL) { continuation.resume(returning: outputURL) }
                else { continuation.resume(throwing: ConversionError.pdfCreationFailed) }
            }
        }
    }
    
    func reorderPages(in pdfURL: URL, newOrder: [Int]) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if pdfURL.pathExtension.lowercased() == "epub" {
                     // EPUB Reorder
                     Task {
                         do {
                             let allImages = try await self.extractImageURLs(from: pdfURL)
                             var reorderedImages: [URL] = []
                             for index in newOrder {
                                 if index < allImages.count {
                                     reorderedImages.append(allImages[index])
                                 }
                             }
                             
                             // Regenerate
                             // Need generic settings, or preserve?
                             // Since we are modifying the file, we should probably preserve settings if possible, or use current global settings.
                             // Using current conversionSettings is safest default.
                             
                             let generator = await EPUBGenerator(settings: self.conversionSettings.epubSettings, metadata: PDFMetadata(), compressionQuality: 1.0)
                             // Use metadata from existing file if possible? Ideally yes. But reading it is hard.
                             // We can fetch from convertedPDFs array via URL matching?
                             
                             let outputName = pdfURL.deletingPathExtension().lastPathComponent
                             let (newEPUB, _) = try await generator.generateEPUB(from: reorderedImages, outputName: outputName)
                             
                             // Replace
                             try? FileManager.default.removeItem(at: pdfURL)
                             try FileManager.default.moveItem(at: newEPUB, to: pdfURL)
                             
                             continuation.resume(returning: pdfURL)
                         } catch {
                             continuation.resume(throwing: error)
                         }
                     }
                     return
                }
                
                guard let document = PDFDocument(url: pdfURL) else {
                    continuation.resume(throwing: ConversionError.pdfCreationFailed)
                    return
                }
                let newDocument = PDFDocument()
                for (newIndex, oldIndex) in newOrder.enumerated() {
                    if let page = document.page(at: oldIndex) { newDocument.insert(page, at: newIndex) }
                }
                if newDocument.write(to: pdfURL) { continuation.resume(returning: pdfURL) }
                else { continuation.resume(throwing: ConversionError.pdfCreationFailed) }
            }
        }
    }
    
    func splitPDF(at url: URL, maxSizeMB: Int, progressHandler: @escaping (Double) -> Void) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: url) else {
                    continuation.resume(throwing: ConversionError.pdfCreationFailed)
                    return
                }
                let pageCount = document.pageCount
                let maxBytes = maxSizeMB * 1024 * 1024
                var parts: [URL] = []
                var currentPart = PDFDocument()
                var currentPartIndex = 1
                var pagesInCurrentPart = 0
                let baseName = url.deletingPathExtension().lastPathComponent
                let originalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                
                for i in 0..<pageCount {
                    autoreleasepool {
                        if let page = document.page(at: i) {
                            currentPart.insert(page, at: pagesInCurrentPart)
                            pagesInCurrentPart += 1
                        }
                    }
                    
                    // Periodic memory cleanup
                    if i % 10 == 0 {
                        await Task.yield()
                    }
                    
                    let estimatedPartSize = (Int64(pagesInCurrentPart) * originalSize) / Int64(pageCount)
                    if estimatedPartSize >= maxBytes || i == pageCount - 1 {
                        let partURL = self.outputDirectory.appendingPathComponent("\(baseName)_part\(currentPartIndex).pdf")
                        if currentPart.write(to: partURL) { parts.append(partURL) }
                        
                        currentPart = PDFDocument()
                        currentPartIndex += 1
                        pagesInCurrentPart = 0
                    }
                    progressHandler(Double(i + 1) / Double(pageCount))
                }
                continuation.resume(returning: parts)
            }
        }
    }
    
    func addToLibrary(_ url: URL, collectionId: UUID? = nil, explicitPageCount: Int? = nil) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? Int64) ?? 0
        
        var pageCount = 0
        if let count = explicitPageCount {
            pageCount = count
        } else if url.pathExtension.lowercased() == "pdf" {
            pageCount = PDFDocument(url: url)?.pageCount ?? 0
        }
        // EPUB page count detection would require unzipping, so explicit passing is better
        
        // Dedupe: Remove existing entry if it exists
        if let existingIndex = convertedPDFs.firstIndex(where: { $0.url == url }) {
            convertedPDFs.remove(at: existingIndex)
        }
        
        let pdf = ConvertedPDF(name: url.deletingPathExtension().lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, collectionId: collectionId)
        convertedPDFs.insert(pdf, at: 0)
        savePDFs()
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) {
        try? fileManager.removeItem(at: pdf.url)
        convertedPDFs.removeAll { $0.id == pdf.id }
        savePDFs()
    }
    
    func updatePDFMetadata(_ pdf: ConvertedPDF, metadata: PDFMetadata) {
        if let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[index].metadata = metadata
            savePDFs()
        }
    }
    
    func movePDFToCollection(_ pdf: ConvertedPDF, collectionId: UUID?) {
        if let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[index].collectionId = collectionId
            savePDFs()
        }
    }
    
    func createCollection(name: String, icon: String = "folder.fill", color: String = "blue") {
        let collection = PDFCollection(name: name, icon: icon, color: color)
        collections.append(collection)
        saveCollections()
    }
    
    func deleteCollection(_ collection: PDFCollection) {
        for i in 0..<convertedPDFs.count {
            if convertedPDFs[i].collectionId == collection.id { convertedPDFs[i].collectionId = nil }
        }
        collections.removeAll { $0.id == collection.id }
        saveCollections()
        savePDFs()
    }
    
    func pdfsInCollection(_ collectionId: UUID?) -> [ConvertedPDF] {
        return convertedPDFs.filter { $0.collectionId == collectionId }
    }
    
    func addKindleDevice(_ device: KindleDevice) {
        var newDevice = device
        if kindleDevices.isEmpty { newDevice.isDefault = true }
        kindleDevices.append(newDevice)
        saveKindleDevices()
    }
    
    func removeKindleDevice(_ device: KindleDevice) {
        kindleDevices.removeAll { $0.id == device.id }
        if device.isDefault && !kindleDevices.isEmpty { kindleDevices[0].isDefault = true }
        saveKindleDevices()
    }
    
    func setDefaultKindleDevice(_ device: KindleDevice) {
        for i in 0..<kindleDevices.count { kindleDevices[i].isDefault = (kindleDevices[i].id == device.id) }
        saveKindleDevices()
    }
    
    func updateKindleDevice(_ device: KindleDevice) {
        if let index = kindleDevices.firstIndex(where: { $0.id == device.id }) {
            kindleDevices[index] = device
            saveKindleDevices()
        }
    }
    
    func loadSavedData() {
        if let data = UserDefaults.standard.data(forKey: "convertedPDFs"), let pdfs = try? JSONDecoder().decode([ConvertedPDF].self, from: data) {
            convertedPDFs = pdfs.filter { fileManager.fileExists(atPath: $0.url.path) }
        }
        if let data = UserDefaults.standard.data(forKey: "pdfCollections"), let cols = try? JSONDecoder().decode([PDFCollection].self, from: data) { collections = cols }
        if let data = UserDefaults.standard.data(forKey: "kindleDevices"), let devices = try? JSONDecoder().decode([KindleDevice].self, from: data) { kindleDevices = devices }
        if let data = UserDefaults.standard.data(forKey: "conversionSettings"), let settings = try? JSONDecoder().decode(ConversionSettings.self, from: data) { conversionSettings = settings }
    }
    
    internal func savePDFs() { markNeedsSave() }
    private func saveCollections() { markNeedsSave() }
    private func saveKindleDevices() { markNeedsSave() }
    func saveSettings() { markNeedsSave() }
    func savePresets() { markNeedsSave() }
    func saveSendHistory() { markNeedsSave() }
    
    // Force re-sync of file structure
    func scanForPDFs() {
        loadSavedData()
        
        // Scan directory for new files
        guard let files = try? fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else { return }
        
        var hasChanges = false
        for fileURL in files {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "pdf" || ext == "epub" else { continue }
            
            // Check if already known
            if !convertedPDFs.contains(where: { $0.url.lastPathComponent == fileURL.lastPathComponent }) {
                let name = fileURL.deletingPathExtension().lastPathComponent
                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                // Minimal metadata fetch
                let pageCount = (PDFDocument(url: fileURL)?.pageCount) ?? 0
                let newPDF = ConvertedPDF(name: name, url: fileURL, pageCount: pageCount, fileSize: Int64(fileSize))
                convertedPDFs.append(newPDF)
                hasChanges = true
            }
        }
        
        if hasChanges {
            convertedPDFs.sort { $0.dateAdded > $1.dateAdded }
            savePDFs()
        }
    }
    
    // MARK: - Lazy Loading & Caching
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        // Check NSCache first for fast lookup
        if let cached = thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
            return cached
        }
        
        // Try to load from saved coverImageData
        if let imageData = pdf.coverImageData,
           let image = UIImage(data: imageData) {
            // Cache it for next time
            thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
            return image
        }
        
        // Generate thumbnail if we don't have one
        if pdf.coverImageData == nil {
            generateCoverThumbnail(for: pdf)
        }
        
        return nil
    }

    // MARK: - Incremental Save
    
    func markNeedsSave() {
        needsSave = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveDataIfNeeded()
            }
        }
    }
    
    private func saveDataIfNeeded() {
        guard needsSave else { return }
        saveDataNow()
        needsSave = false
    }
    
    private func saveDataNow() {
        if let data = try? JSONEncoder().encode(convertedPDFs) { UserDefaults.standard.set(data, forKey: "convertedPDFs") }
        if let data = try? JSONEncoder().encode(collections) { UserDefaults.standard.set(data, forKey: "pdfCollections") }
        if let data = try? JSONEncoder().encode(kindleDevices) { UserDefaults.standard.set(data, forKey: "kindleDevices") }
        if let data = try? JSONEncoder().encode(conversionSettings) { UserDefaults.standard.set(data, forKey: "conversionSettings") }
        if let data = try? JSONEncoder().encode(sendHistory) { UserDefaults.standard.set(data, forKey: "sendHistory") }
        if let data = try? JSONEncoder().encode(conversionPresets) { UserDefaults.standard.set(data, forKey: "conversionPresets") }
    }
    
    // MARK: - New Feature Implementation
    
    func toggleFavorite(_ pdf: ConvertedPDF) {
        if let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[index].isFavorite.toggle()
            savePDFs()
        }
    }
    
    func generateCoverThumbnail(for pdf: ConvertedPDF) {
        // Accessing main-actor property convertedPDFs
        guard let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }), convertedPDFs[index].coverImageData == nil else { return }
        
        Task.detached(priority: .utility) {
            let ext = pdf.url.pathExtension.lowercased()
            var imageData: Data? = nil
            
            if ext == "pdf" {
                if let document = PDFDocument(url: pdf.url), let page = document.page(at: 0) {
                     let thumbnail = page.thumbnail(of: CGSize(width: 200, height: 280), for: .mediaBox)
                     imageData = thumbnail.jpegData(compressionQuality: 0.7)
                }
            } else if ext == "epub" {
                // EPUB Thumbnail Generation
                do {
                    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    
                    try FileManager.default.unzipItem(at: pdf.url, to: tempDir)
                    
                    // Simple heuristic: Take the first found image that looks like a cover
                    // (Sorting alphanumeric usually puts cover first: e.g. cover.jpg, image001.jpg)
                    if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                        var images: [URL] = []
                        while let fileURL = enumerator.nextObject() as? URL {
                            if ["jpg", "jpeg", "png", "webp"].contains(fileURL.pathExtension.lowercased()) {
                                images.append(fileURL)
                            }
                        }
                        
                        // Sort mainly by path to get "OEBPS/images/page1.jpg" or "cover.jpg"
                        images.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                        
                        if let firstImageURL = images.first,
                           let originalImage = UIImage(contentsOfFile: firstImageURL.path) {
                           
                             // Resize to thumbnail
                             let targetSize = CGSize(width: 200, height: 280)
                             let renderer = UIGraphicsImageRenderer(size: targetSize)
                             let thumbnail = renderer.image { _ in
                                 originalImage.draw(in: CGRect(origin: .zero, size: targetSize))
                             }
                             
                             imageData = thumbnail.jpegData(compressionQuality: 0.7)
                        }
                    }
                } catch {
                    print("Failed to generate EPUB thumbnail: \(error)")
                }
            }
            
            if let finalData = imageData, let image = UIImage(data: finalData) {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let idx = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                        self.convertedPDFs[idx].coverImageData = finalData
                        self.thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
                        self.markNeedsSave()
                    }
                }
            }
        }
    }
    
    func recordSend(pdf: ConvertedPDF, device: KindleDevice) {
        let record = SendHistoryRecord(pdf: pdf, device: device.deviceType)
        sendHistory.insert(record, at: 0)
        if let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[index].lastSentDate = Date()
            convertedPDFs[index].lastSentDevice = device.name
        }
        saveSendHistory()
        savePDFs()
    }
    
    func mergePDFs(_ pdfs: [ConvertedPDF], outputName: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let mergedDocument = PDFDocument()
                var pageIndex = 0
                for pdf in pdfs {
                    guard let document = PDFDocument(url: pdf.url) else { continue }
                    for i in 0..<document.pageCount {
                        if let page = document.page(at: i) {
                            mergedDocument.insert(page, at: pageIndex)
                            pageIndex += 1
                        }
                    }
                }
                let outputURL = self.outputDirectory.appendingPathComponent("\(outputName).pdf")
                if mergedDocument.write(to: outputURL) {
                    continuation.resume(returning: outputURL)
                } else {
                    continuation.resume(throwing: NSError(domain: "Merge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to save"]))
                }
            }
        }
    }
    
    func mergeEPUBs(_ epubs: [ConvertedPDF], outputName: String) async throws -> URL {
        let urls = epubs.map { $0.url }
        
        // Simple metadata for merged file
        var metadata = PDFMetadata()
        metadata.title = outputName
        if let first = epubs.first {
            metadata.author = first.metadata.author
        }
        
        let outputURL = self.outputDirectory.appendingPathComponent("\(outputName).epub")
        
        // Panel detection already happened during CBZ → EPUB conversion
        // The EPUB files already contain panel manifests if enabled
        if conversionSettings.epubSettings.enablePanelView {
            await MainActor.run { 
                self.processingStatus = "Merging EPUBs with panel data..." 
            }
        }
        
        // Merge EPUBs - panel manifests are already embedded in source EPUBs
        let (finalEPUB, pageCount) = try await EPUBMerger.mergeEPUBs(
            sourceURLs: urls,
            outputURL: outputURL,
            metadata: metadata,
            settings: conversionSettings.epubSettings,
            precomputedManifest: nil,  // Let merger extract from source EPUBs
            onStatusUpdate: { status in
                Task { @MainActor in self.processingStatus = status }
            }
        )
        
        // Store the merged result
        await MainActor.run {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalEPUB.path)[.size] as? Int64) ?? 0
            let pdf = ConvertedPDF(
                name: outputName,
                url: finalEPUB,
                pageCount: pageCount,
                fileSize: fileSize,
                metadata: metadata
            )
            self.convertedPDFs.append(pdf)
            self.processingStatus = "Merge complete!"
        }
        
        return finalEPUB
    }
    
    func mergeMixedFiles(files: [ConvertedPDF], outputName: String, targetFormat: OutputFormat) async throws -> URL {
        // 1. Convert everything to target format
        var readyURLs: [URL] = []
        var tempPDFs: [ConvertedPDF] = [] 
        
        for file in files {
            let ext = file.url.pathExtension.lowercased()
            let isTarget = (targetFormat == .pdf && ext == "pdf") || (targetFormat == .epub && ext == "epub")
            
            if isTarget {
                readyURLs.append(file.url)
                tempPDFs.append(file)
            } else {
                // Convert
                if targetFormat == .pdf {
                     let pdfURL = try await convertToPDF(from: file.url, customName: "\(file.name)_temp", settings: conversionSettings) { _ in }
                     readyURLs.append(pdfURL)
                     tempPDFs.append(ConvertedPDF(name: file.name, url: pdfURL, pageCount: 0, fileSize: 0)) // dummy
                } else {
                     let (epubURLs, _) = try await convertToEPUB(from: file.url, settings: conversionSettings) { _ in }
                     if let first = epubURLs.first {
                         readyURLs.append(first)
                         tempPDFs.append(ConvertedPDF(name: file.name, url: first, pageCount: 0, fileSize: 0))
                     }
                }
            }
        }
        
        // 2. Merge
        if targetFormat == .pdf {
            // Re-wrap URLs into ConvertedPDFs for mergePDFs or just direct?
            // mergePDFs takes [ConvertedPDF].
            // We can just create dummy objects or refactor mergePDFs. 
            // Creating dummy objects is easier.
            return try await mergePDFs(tempPDFs, outputName: outputName)
        } else {
            // mergeEPUBs takes [ConvertedPDF].
            let dummyEPUBs = readyURLs.map { ConvertedPDF(name: "temp", url: $0, pageCount: 0, fileSize: 0) }
            return try await mergeEPUBs(dummyEPUBs, outputName: outputName)
        }
    }
    
    func findDuplicates() async -> [DuplicateGroup] {
        let pdfs = await MainActor.run { convertedPDFs }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hashGroups: [String: [ConvertedPDF]] = [:]
                for pdf in pdfs {
                    if let data = try? Data(contentsOf: pdf.url) {
                        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                        hashGroups[hash, default: []].append(pdf)
                    }
                }
                let duplicates = hashGroups.filter { $0.value.count > 1 }.map { DuplicateGroup(fileHash: $0.key, pdfs: $0.value) }
                continuation.resume(returning: duplicates)
            }
        }
    }
    
    func extractPages(from pdf: ConvertedPDF, pageIndices: [Int], asImages: Bool) async throws -> [URL] {
        let extractionDir = self.outputDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try? FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                if pdf.url.pathExtension.lowercased() == "epub" {
                     // EPUB Extraction
                     do {
                         let allImages = try await self.extractImageURLs(from: pdf.url)
                         var outputURLs: [URL] = []
                         
                         for pageIndex in pageIndices {
                             guard pageIndex < allImages.count else { continue }
                             let imageURL = allImages[pageIndex]
                             
                             if asImages {
                                 // Copy image to extraction dir
                                 let destURL = extractionDir.appendingPathComponent("\(pdf.name)_page\(pageIndex + 1).\(imageURL.pathExtension)")
                                 try FileManager.default.copyItem(at: imageURL, to: destURL)
                                 outputURLs.append(destURL)
                             } else {
                                 // Create single page PDF
                                 if let image = UIImage(contentsOfFile: imageURL.path),
                                    let page = PDFPage(image: image) {
                                     let singlePageDoc = PDFDocument()
                                     singlePageDoc.insert(page, at: 0)
                                     let url = extractionDir.appendingPathComponent("\(pdf.name)_page\(pageIndex + 1).pdf")
                                     if singlePageDoc.write(to: url) { outputURLs.append(url) }
                                 }
                             }
                         }
                         continuation.resume(returning: outputURLs)
                     } catch {
                         continuation.resume(throwing: error)
                     }
                     return
                }
                
                guard let document = PDFDocument(url: pdf.url) else {
                    continuation.resume(throwing: NSError(domain: "Extract", code: 1, userInfo: [:]))
                    return
                }
                
                var outputURLs: [URL] = []
                for pageIndex in pageIndices {
                    if let page = document.page(at: pageIndex) {
                        if asImages {
                            // Convert page to image
                             // Note: PDFPage.thumbnail might be low res. 
                             // Better to use draw(with: .mediaBox)
                             let pageRect = page.bounds(for: .mediaBox)
                             let renderer = UIGraphicsImageRenderer(size: pageRect.size)
                             let img = renderer.image { ctx in
                                 UIColor.white.set()
                                 ctx.fill(pageRect)
                                 ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                                 ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                                 page.draw(with: .mediaBox, to: ctx.cgContext)
                             }
                             
                             let url = extractionDir.appendingPathComponent("\(pdf.name)_page\(pageIndex + 1).jpg")
                             if let data = img.jpegData(compressionQuality: 0.8) {
                                 try? data.write(to: url)
                                 outputURLs.append(url)
                             }
                        } else {
                            // Single Page PDF
                            let singlePageDoc = PDFDocument()
                            singlePageDoc.insert(page, at: 0)
                            let url = extractionDir.appendingPathComponent("\(pdf.name)_page\(pageIndex + 1).pdf")
                            if singlePageDoc.write(to: url) {
                                outputURLs.append(url)
                            }
                        }
                    }
                }
                continuation.resume(returning: outputURLs)
            }
        }
    }

    
    func savePreset(_ preset: ConversionPreset) {
        if let index = conversionPresets.firstIndex(where: { $0.id == preset.id }) {
            conversionPresets[index] = preset
        } else {
            conversionPresets.append(preset)
        }
        savePresets()
    }
    
    func deletePreset(_ preset: ConversionPreset) {
        conversionPresets.removeAll { $0.id == preset.id }
        savePresets()
    }
    
    func applyPreset(_ preset: ConversionPreset) {
        conversionSettings = preset.settings
        saveSettings()
    }
    
    func calculateStorageInfo() -> StorageInfo {
        let totalSize = convertedPDFs.reduce(0) { $0 + $1.fileSize }
        let largestFile = convertedPDFs.max { $0.fileSize < $1.fileSize }
        let oldestFile = convertedPDFs.min { $0.dateAdded < $1.dateAdded }
        var byCollection: [(collection: PDFCollection?, size: Int64, count: Int)] = []
        let uncategorized = convertedPDFs.filter { $0.collectionId == nil }
        if !uncategorized.isEmpty {
            byCollection.append((nil, uncategorized.reduce(0) { $0 + $1.fileSize }, uncategorized.count))
        }
        for collection in collections {
            let inCollection = convertedPDFs.filter { $0.collectionId == collection.id }
            if !inCollection.isEmpty {
                byCollection.append((collection, inCollection.reduce(0) { $0 + $1.fileSize }, inCollection.count))
            }
        }
        return StorageInfo(totalSize: totalSize, pdfCount: convertedPDFs.count, largestFile: largestFile, oldestFile: oldestFile, byCollection: byCollection.sorted { $0.size > $1.size })
    }
    
    func batchRename(pdfs: [ConvertedPDF], pattern: String, startNumber: Int = 1) {
        for (index, pdf) in pdfs.enumerated() {
            let newName = pattern.replacingOccurrences(of: "{n}", with: "\(startNumber + index)")
                .replacingOccurrences(of: "{name}", with: pdf.name)
                .replacingOccurrences(of: "{series}", with: pdf.metadata.series)
            let directory = pdf.url.deletingLastPathComponent()
            let newURL = directory.appendingPathComponent("\(newName).pdf")
            guard !FileManager.default.fileExists(atPath: newURL.path) || newURL == pdf.url else { continue }
            do {
                try FileManager.default.moveItem(at: pdf.url, to: newURL)
                if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    convertedPDFs[idx].name = newName
                    // Need to update the URL in struct? struct is value type, array holds copies.
                    // This is why we use index. But we need to recreate the struct with new URL
                     let old = convertedPDFs[idx]
                     var newPDF = ConvertedPDF(name: newName, url: newURL, pageCount: old.pageCount, fileSize: old.fileSize, collectionId: old.collectionId)
                     newPDF.metadata = old.metadata
                     newPDF.isFavorite = old.isFavorite
                     newPDF.coverImageData = old.coverImageData
                     newPDF.fileHash = old.fileHash
                     newPDF.lastSentDate = old.lastSentDate
                     newPDF.lastSentDevice = old.lastSentDevice
                     convertedPDFs[idx] = newPDF
                }
            } catch {
                print("Rename failed: \(error)")
            }
        }
        savePDFs()
    }
    
    func autoOrganize() {
        for i in 0..<convertedPDFs.count {
            let pdf = convertedPDFs[i]
            guard pdf.collectionId == nil else { continue }
            if !pdf.metadata.series.isEmpty {
                if let collection = collections.first(where: { $0.name.localizedCaseInsensitiveContains(pdf.metadata.series) }) {
                    convertedPDFs[i].collectionId = collection.id
                    continue
                }
            }
            let name = pdf.name.lowercased()
            for collection in collections {
                if name.contains(collection.name.lowercased()) {
                    convertedPDFs[i].collectionId = collection.id
                    break
                }
            }
        }
        savePDFs()
    }
    
    func clearSendHistory() {
        sendHistory.removeAll()
        saveSendHistory()
    }
    
    // MARK: - Post-Conversion Panel Editing
    
    // MARK: - Helpers

    // MARK: - Save Logic
    private func saveEditedPanels(session: PanelEditSession, originalPDF: ConvertedPDF) async {
        await MainActor.run { self.processingStatus = "Saving changes..." }
        
        // Convert Session back to Manifest
        var allPagePanels: [EPUBPanelManifest.PagePanels] = []
        
        for page in session.pages {
            // Memory Optimization: Load data safely
            if let data = try? Data(contentsOf: page.imageURL), 
               let image = UIImage(data: data), 
               let cgImage = image.cgImage {
                
                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                
                // FIX: Use 'origin.x' and 'origin.y' for CGRect access
                let panels = page.panels.sorted { $0.order < $1.order }
                                      .map { rect -> PanelRegion in
                                          // Calculate normalized coordinates
                                          return PanelRegion(
                                              x: rect.rect.origin.x / Double(imageSize.width),
                                              y: rect.rect.origin.y / Double(imageSize.height),
                                              width: rect.rect.width / Double(imageSize.width),
                                              height: rect.rect.height / Double(imageSize.height),
                                              pageIndex: page.pageNumber - 1
                                          )
                                      }
                
                if !panels.isEmpty {
                    allPagePanels.append(EPUBPanelManifest.PagePanels(
                        pageNumber: page.pageNumber,
                        imageFile: "page\(page.pageNumber).jpg", 
                        panels: panels
                    ))
                }
            }
        }
        
        let newManifest = EPUBPanelManifest(
            version: "1.0",
            readingDirection: session.readingDirection == .rightToLeft ? "rtl" : "ltr",
            pages: allPagePanels
        )
        
        do {
            // Re-merge with new manifest
            let _ = try await EPUBMerger.mergeEPUBs(
                sourceURLs: [originalPDF.url],
                outputURL: originalPDF.url, // Overwrite
                metadata: originalPDF.metadata,
                settings: conversionSettings.epubSettings,
                precomputedManifest: newManifest,
                onStatusUpdate: { _ in }
            )
            
            await MainActor.run { 
                self.processingStatus = "Saved!"
                self.scanForPDFs()
            }
        } catch {
            print("Failed to save: \(error)")
            await MainActor.run { self.processingStatus = "Save failed." }
        }
        
        // Final cleanup
        if let tempDir = session.sessionTempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Page Manager Logic

    func deletePages(from pdf: ConvertedPDF, pagesToDelete: Set<Int>) async throws {
        // 1. Validation
        guard pdf.url.pathExtension.lowercased() == "pdf" else {
            throw NSError(domain: "PageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Page deletion is currently only supported for PDF files."])
        }
        
        await MainActor.run { self.processingStatus = "Removing pages..." }
        
        let sourceURL = pdf.url
        let fileManager = FileManager.default
        
        // 2. Create Temp Output
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempOutput = tempDir.appendingPathComponent("temp_trimmed.pdf")
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // 3. Load PDF
                    guard let document = PDFDocument(url: sourceURL) else {
                        throw NSError(domain: "PageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not load source PDF."])
                    }
                    
                    // 4. Rebuild PDF without deleted pages
                    let newDocument = PDFDocument()
                    var newIndex = 0
                    
                    for i in 0..<document.pageCount {
                        if !pagesToDelete.contains(i) {
                            if let page = document.page(at: i) {
                                newDocument.insert(page, at: newIndex)
                                newIndex += 1
                            }
                        }
                    }
                    
                    // 5. Save and Swap
                    if newDocument.write(to: tempOutput) {
                        // Replace original file safely
                        let backupURL = sourceURL.appendingPathExtension("bak")
                        try? fileManager.moveItem(at: sourceURL, to: backupURL)
                        
                        do {
                            try fileManager.moveItem(at: tempOutput, to: sourceURL)
                            try? fileManager.removeItem(at: backupURL) // Delete backup if successful
                            try? fileManager.removeItem(at: tempDir)
                            
                            // 6. Update Library Data
                            await MainActor.run {
                                self.processingStatus = "Pages removed!"
                                self.scanForPDFs() // Refreshes page count and file size in the list
                            }
                            continuation.resume()
                        } catch {
                            // Restore backup if move failed
                            try? fileManager.moveItem(at: backupURL, to: sourceURL)
                            throw error
                        }
                    } else {
                        throw NSError(domain: "PageManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write new PDF file."])
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // Helper used by PageManagerView
    func extractPDFImages(from url: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        guard let document = PDFDocument(url: url) else { return [] }
        var images: [UIImage] = []
        let pageCount = document.pageCount
        
        for i in 0..<pageCount {
            if let page = document.page(at: i) {
                let pageRect = page.bounds(for: .mediaBox)
                // Use a reasonable thumbnail size to avoid memory issues with large PDFs
                let targetSize = CGSize(width: 300, height: 400) 
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                
                let image = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(CGRect(origin: .zero, size: targetSize))
                    
                    ctx.cgContext.translateBy(x: 0.0, y: targetSize.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    
                    // Scale page to fit target size
                    let scaleX = targetSize.width / pageRect.width
                    let scaleY = targetSize.height / pageRect.height
                    let scale = min(scaleX, scaleY)
                    
                    ctx.cgContext.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                images.append(image)
            }
            if i % 5 == 0 { progressHandler(Double(i) / Double(pageCount)) }
        }
        progressHandler(1.0)
        return images
    }
}

// MARK: - SUPPORTING STRUCTS

struct SendHistoryRecord: Identifiable, Codable {
    let id: UUID
    let pdfName: String
    let pdfURL: URL
    let sentDate: Date
    let deviceName: String
    
    init(pdf: ConvertedPDF, device: KindleDeviceType) {
        self.id = UUID()
        self.pdfName = pdf.name
        self.pdfURL = pdf.url
        self.sentDate = Date()
        self.deviceName = device.rawValue
    }
}

struct ConversionPreset: Identifiable, Codable {
    let id: UUID
    let name: String
    let settings: ConversionSettings
    let dateCreated: Date
    var isDefault: Bool = false
    
    var icon: String { "slider.horizontal.3" }
    
    init(name: String, settings: ConversionSettings, isDefault: Bool = false) {
        self.id = UUID()
        self.name = name
        self.settings = settings
        self.dateCreated = Date()
        self.isDefault = isDefault
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case name = "Name"
    case size = "Size"
    case pageCount = "Page Count"
    
    var id: String { rawValue }
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let hash: String
    let files: [ConvertedPDF]
    
    // Custom init to match usage
    init(fileHash: String, pdfs: [ConvertedPDF]) {
        self.hash = fileHash
        self.files = pdfs
    }
    
    var totalSize: Int64 {
        files.reduce(0) { $0 + $1.fileSize }
    }
}

struct StorageInfo {
    let totalSize: Int64
    let pdfCount: Int
    let largestFile: ConvertedPDF?
    let oldestFile: ConvertedPDF?
    let byCollection: [(collection: PDFCollection?, size: Int64, count: Int)]
    
    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}



struct BackupData: Codable {
    let date: Date
    let version: String
    let pdfs: [ConvertedPDF]
    let collections: [PDFCollection]
    let devices: [KindleDevice]
    let settings: ConversionSettings
    let presets: [ConversionPreset]
    let history: [SendHistoryRecord]
}

extension ConversionManager {
    func createBackupData() -> BackupData {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return BackupData(
            date: Date(),
            version: version,
            pdfs: convertedPDFs,
            collections: collections,
            devices: kindleDevices,
            settings: conversionSettings,
            presets: conversionPresets,
            history: sendHistory
        )
    }
    
    func restoreFromBackup(_ backup: BackupData) {
        convertedPDFs = backup.pdfs
        collections = backup.collections
        kindleDevices = backup.devices
        conversionSettings = backup.settings
        conversionPresets = backup.presets
        sendHistory = backup.history
        
        savePDFs()
        saveCollections()
        saveKindleDevices()
        saveSettings()
        savePresets()
        saveSendHistory()
    }
    func autoOrganize(by method: OrganizationMethod) {
        // Simple implementation for now - just logs
        print("Auto organizing by: \(method)")
        // Actual implementation would involve moving files or updating metadata based on the method
        // For now, we stub this out to fix the build
        objectWillChange.send()
    }
    
    func batchRename(pattern: String, startNumber: Int) {
        // Simple implementation for now
        print("Batch renaming with pattern: \(pattern), start: \(startNumber)")
        // Logic to iterate through PDFs and rename them
        // Stub to fix build
        objectWillChange.send()
    }
}

enum OrganizationMethod: String, CaseIterable, Identifiable {
    case alphabetical = "Alphabetical"
    case dateAdded = "Date Added"
    
    var id: String { rawValue }
}

// EPUBtoPDFConverter moved to its own file.


