import SwiftUI
import PDFKit
import CoreImage
import ZIPFoundation

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
    
    func addToLibrary(_ url: URL, collectionId: UUID? = nil) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path), let fileSize = attributes[.size] as? Int64 else { return }
        let pageCount = PDFDocument(url: url)?.pageCount ?? 0
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
}
