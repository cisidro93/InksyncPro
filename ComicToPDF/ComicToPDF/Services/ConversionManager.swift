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
    let pageCount: Int
    let fileSize: Int64
    var collectionId: UUID?
    var metadata: PDFMetadata
    var isFavorite: Bool = false
    var coverImageData: Data? = nil
    var fileHash: String? = nil
    var lastSentDate: Date? = nil
    var lastSentDevice: String? = nil
    
    init(name: String, url: URL, pageCount: Int, fileSize: Int64, collectionId: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.dateAdded = Date()
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.collectionId = collectionId
        self.metadata = PDFMetadata()
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
    
    var errorDescription: String? {
        switch self {
        case .noImagesFound: return "No images found in the archive"
        case .unsupportedFormat: return "Unsupported archive format"
        case .pdfCreationFailed: return "Failed to create PDF"
        case .compressionFailed: return "Failed to compress images"
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
// MARK: - CONVERSION MANAGER
// ============================================================================

@MainActor
class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var collections: [PDFCollection] = []
    @Published var kindleDevices: [KindleDevice] = []
    @Published var conversionSettings = ConversionSettings()
    @Published var sendHistory: [SendHistoryRecord] = []
    @Published var conversionPresets: [ConversionPreset] = []
    @Published var searchText: String = ""
    @Published var filterFavoritesOnly: Bool = false
    @Published var filterCollection: UUID? = nil
    @Published var sortOption: SortOption = .dateAdded
    
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
        case .name: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    
    private let fileManager = FileManager.default
    private let outputDirectory: URL
    
    init() {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputDirectory = documentsPath.appendingPathComponent("ConvertedPDFs", isDirectory: true)
        try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        loadSavedData()
    }
    
    func convertToPDF(from sourceURL: URL, customName: String? = nil, settings: ConversionSettings? = nil, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        let config = settings ?? conversionSettings
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
            let url = try await convertToEPUB(from: sourceURL, settings: config, progressHandler: progressHandler)
            outputURLs.append(url)
            addToLibrary(url, explicitPageCount: 0) // EPUB page count not easily available without unzip
            
        case .both:
            // Split progress: 50% for PDF, 50% for EPUB
            let pdfURL = try await convertToPDF(from: sourceURL, settings: config) { p in
                progressHandler(p * 0.5)
            }
            outputURLs.append(pdfURL)
            addToLibrary(pdfURL)
            
            let epubURL = try await convertToEPUB(from: sourceURL, settings: config) { p in
                progressHandler(0.5 + p * 0.5)
            }
            outputURLs.append(epubURL)
            addToLibrary(epubURL, explicitPageCount: 0)
        }
        
        return outputURLs
    }
    
    func convertToEPUB(from sourceURL: URL, settings: ConversionSettings? = nil, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        let config = settings ?? conversionSettings
        let outputName = sourceURL.deletingPathExtension().lastPathComponent
        
        // Check if source is marked as PDF or has PDF extension
        let isPDF = sourceURL.pathExtension.lowercased() == "pdf"
        
        if isPDF {
            let tempOutput = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("\(outputName).epub")
            try? FileManager.default.createDirectory(at: tempOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            let converter = PDFToEPUBConverter()
            var options = PDFToEPUBConverter.ConversionOptions.default
            
            // Map settings to options
            if config.compressionQuality == .custom {
                options.imageQuality = config.customJpegQuality
            } else {
                options.imageQuality = config.compressionQuality.values.quality
            }
            options.title = outputName
            
            return try await converter.convert(pdfURL: sourceURL, to: self.outputDirectory.appendingPathComponent("\(outputName).epub"), options: options) { progress in
                progressHandler(progress.percentage)
            }
            
        } else {
            // Existing Logic for Archive -> EPUB
            var images = try await extractImages(from: sourceURL) { progress in
                progressHandler(progress * 0.3)
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
            
            // Enhance images
            let processedImages = try await processImages(images, scale: scale, jpegQuality: jpegQuality, enhancement: config.imageEnhancement, targetSize: nil) { progress in
                progressHandler(0.3 + progress * 0.4)
            }
            
            // Metadata
            var metadata = PDFMetadata()
            metadata.title = outputName
            
            let generator = EPUBGenerator(settings: config.epubSettings, metadata: metadata)
            let epubURL = try await generator.generateEPUB(from: processedImages, outputName: outputName)
            
            progressHandler(1.0)
            return epubURL
        }
    }
    
    private func extractImages(from url: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
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
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var processedImages: [UIImage] = []
                let context = CIContext()
                
                for (index, image) in images.enumerated() {
                    autoreleasepool {
                        var processed = image
                        
                        if enhancement.enabled, let ciImage = CIImage(image: image) {
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
                        newSize = CGSize(width: newSize.width * scale, height: newSize.height * scale)
                        
                        if newSize != processed.size {
                            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                            processed.draw(in: CGRect(origin: .zero, size: newSize))
                            if let resized = UIGraphicsGetImageFromCurrentImageContext() { processed = resized }
                            UIGraphicsEndImageContext()
                        }
                        
                        if jpegQuality < 1.0 {
                            if let jpegData = processed.jpegData(compressionQuality: jpegQuality), let recompressed = UIImage(data: jpegData) {
                                processed = recompressed
                            }
                        }
                        processedImages.append(processed)
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
            DispatchQueue.global(qos: .userInitiated).async {
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
                    let estimatedPartSize = (Int64(pagesInCurrentPart) * originalSize) / Int64(pageCount)
                    if estimatedPartSize >= maxBytes || i == pageCount - 1 {
                        let partURL = self.outputDirectory.appendingPathComponent("\(baseName)_part\(currentPartIndex).pdf")
                        if currentPart.write(to: partURL) { parts.append(partURL) }
                        currentPart = PDFDocument()
                        pagesInCurrentPart = 0
                        currentPartIndex += 1
                    }
                    DispatchQueue.main.async { progressHandler(Double(i + 1) / Double(pageCount)) }
                }
                continuation.resume(returning: parts)
            }
        }
    }
    
    func addToLibrary(_ url: URL, collectionId: UUID? = nil, explicitPageCount: Int? = nil) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path), let fileSize = attributes[.size] as? Int64 else { return }
        
        var pageCount = 0
        if let count = explicitPageCount {
            pageCount = count
        } else if url.pathExtension.lowercased() == "pdf" {
            pageCount = PDFDocument(url: url)?.pageCount ?? 0
        }
        // EPUB page count detection would require unzipping, so explicit passing is better
        
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
    
    private func loadSavedData() {
        if let data = UserDefaults.standard.data(forKey: "convertedPDFs"), let pdfs = try? JSONDecoder().decode([ConvertedPDF].self, from: data) {
            convertedPDFs = pdfs.filter { fileManager.fileExists(atPath: $0.url.path) }
        }
        if let data = UserDefaults.standard.data(forKey: "pdfCollections"), let cols = try? JSONDecoder().decode([PDFCollection].self, from: data) { collections = cols }
        if let data = UserDefaults.standard.data(forKey: "kindleDevices"), let devices = try? JSONDecoder().decode([KindleDevice].self, from: data) { kindleDevices = devices }
        if let data = UserDefaults.standard.data(forKey: "conversionSettings"), let settings = try? JSONDecoder().decode(ConversionSettings.self, from: data) { conversionSettings = settings }
    }
    
    private func savePDFs() { if let data = try? JSONEncoder().encode(convertedPDFs) { UserDefaults.standard.set(data, forKey: "convertedPDFs") } }
    private func saveCollections() { if let data = try? JSONEncoder().encode(collections) { UserDefaults.standard.set(data, forKey: "pdfCollections") } }
    private func saveKindleDevices() { if let data = try? JSONEncoder().encode(kindleDevices) { UserDefaults.standard.set(data, forKey: "kindleDevices") } }
    func saveSettings() { if let data = try? JSONEncoder().encode(conversionSettings) { UserDefaults.standard.set(data, forKey: "conversionSettings") } }
    
    // MARK: - New Feature Implementation
    
    func toggleFavorite(_ pdf: ConvertedPDF) {
        if let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            convertedPDFs[index].isFavorite.toggle()
            savePDFs()
        }
    }
    
    func generateCoverThumbnail(for pdf: ConvertedPDF) {
        guard let index = convertedPDFs.firstIndex(where: { $0.id == pdf.id }), convertedPDFs[index].coverImageData == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let document = PDFDocument(url: pdf.url), let page = document.page(at: 0) else { return }
            let thumbnail = page.thumbnail(of: CGSize(width: 200, height: 280), for: .mediaBox)
            if let data = thumbnail.jpegData(compressionQuality: 0.7) {
                DispatchQueue.main.async {
                    if let idx = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                        self.convertedPDFs[idx].coverImageData = data
                        self.savePDFs()
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
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let document = PDFDocument(url: pdf.url) else {
                    continuation.resume(throwing: NSError(domain: "Extract", code: 1, userInfo: [:]))
                    return
                }
                let extractionDir = self.outputDirectory.appendingPathComponent("Extracted", isDirectory: true)
                try? FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
                
                var outputURLs: [URL] = []
                for pageIndex in pageIndices {
                    guard let page = document.page(at: pageIndex) else { continue }
                    if asImages {
                        let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
                        if let data = image.jpegData(compressionQuality: 0.9) {
                            let url = extractionDir.appendingPathComponent("\(pdf.name)_page\(pageIndex + 1).jpg")
                            try? data.write(to: url)
                            outputURLs.append(url)
                        }
                    } else {
                        let singlePageDoc = PDFDocument()
                        singlePageDoc.insert(page, at: 0)
                        let url = extractionDir.appendingPathComponent("\(pdf.name)_page\(pageIndex + 1).pdf")
                        if singlePageDoc.write(to: url) { outputURLs.append(url) }
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
                     convertedPDFs[idx] = ConvertedPDF(name: newName, url: newURL, pageCount: old.pageCount, fileSize: old.fileSize, collectionId: old.collectionId)
                     convertedPDFs[idx].metadata = old.metadata
                     convertedPDFs[idx].isFavorite = old.isFavorite
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
    
    private func saveSendHistory() { if let data = try? JSONEncoder().encode(sendHistory) { UserDefaults.standard.set(data, forKey: "sendHistory") } }
    private func savePresets() { if let data = try? JSONEncoder().encode(conversionPresets) { UserDefaults.standard.set(data, forKey: "conversionPresets") } }
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

