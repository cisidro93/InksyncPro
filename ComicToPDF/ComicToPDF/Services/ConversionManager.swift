import SwiftUI
import PDFKit
import Compression

// MARK: - Converted PDF Model

struct ConvertedPDF: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let url: URL
    let dateAdded: Date
    let fileSize: Int64
    let pageCount: Int
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    static func == (lhs: ConvertedPDF, rhs: ConvertedPDF) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Conversion Manager

@MainActor
class ConversionManager: ObservableObject {
    @Published var convertedPDFs: [ConvertedPDF] = []
    @Published var isProcessing = false
    
    @Published var kindleEmail: String {
        didSet { UserDefaults.standard.set(kindleEmail, forKey: "kindleEmail") }
    }
    @Published var imageQuality: Double {
        didSet { UserDefaults.standard.set(imageQuality, forKey: "imageQuality") }
    }
    @Published var autoSplit: Bool {
        didSet { UserDefaults.standard.set(autoSplit, forKey: "autoSplit") }
    }
    @Published var splitThreshold: Int {
        didSet { UserDefaults.standard.set(splitThreshold, forKey: "splitThreshold") }
    }
    
    private let fileManager = FileManager.default
    private let documentsDirectory: URL
    private let pdfDirectory: URL
    
    var totalStorageUsed: String {
        let totalSize = convertedPDFs.reduce(0) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
    
    init() {
        documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        pdfDirectory = documentsDirectory.appendingPathComponent("ConvertedPDFs", isDirectory: true)
        
        try? fileManager.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
        
        kindleEmail = UserDefaults.standard.string(forKey: "kindleEmail") ?? ""
        
        let savedQuality = UserDefaults.standard.double(forKey: "imageQuality")
        imageQuality = savedQuality == 0 ? 0.8 : savedQuality
        
        autoSplit = UserDefaults.standard.bool(forKey: "autoSplit")
        
        let savedThreshold = UserDefaults.standard.integer(forKey: "splitThreshold")
        splitThreshold = savedThreshold == 0 ? 50 : savedThreshold
        
        // Now all properties are initialized, we can access self
        loadSavedPDFs()
    }
    
    func convertToPDF(from sourceURL: URL, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        let fileName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = pdfDirectory.appendingPathComponent("\(fileName).pdf")
        
        try? fileManager.removeItem(at: outputURL)
        
        let images = try await extractImages(from: sourceURL, progressHandler: { progress in
            progressHandler(progress * 0.6)
        })
        
        guard !images.isEmpty else {
            throw ConversionError.noImagesFound
        }
        
        try await createPDF(from: images, outputURL: outputURL, progressHandler: { progress in
            progressHandler(0.6 + progress * 0.4)
        })
        
        return outputURL
    }
    
    func addToLibrary(_ url: URL) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes?[.size] as? Int64 ?? 0
        
        let pageCount: Int
        if let pdfDocument = PDFDocument(url: url) {
            pageCount = pdfDocument.pageCount
        } else {
            pageCount = 0
        }
        
        let pdf = ConvertedPDF(
            id: UUID(),
            name: url.deletingPathExtension().lastPathComponent,
            url: url,
            dateAdded: Date(),
            fileSize: fileSize,
            pageCount: pageCount
        )
        
        if !convertedPDFs.contains(where: { $0.url == url }) {
            convertedPDFs.insert(pdf, at: 0)
            savePDFList()
        }
    }
    
    func removeFromLibrary(_ pdf: ConvertedPDF) {
        try? fileManager.removeItem(at: pdf.url)
        convertedPDFs.removeAll { $0.id == pdf.id }
        savePDFList()
    }
    
    func clearAllPDFs() {
        for pdf in convertedPDFs {
            try? fileManager.removeItem(at: pdf.url)
        }
        convertedPDFs.removeAll()
        savePDFList()
    }
    
    func splitPDF(at url: URL, maxSizeMB: Int, progressHandler: @escaping (Double) -> Void) async throws -> [URL] {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw ConversionError.pdfCreationFailed
        }
        
        let maxBytes = Int64(maxSizeMB * 1024 * 1024)
        var parts: [URL] = []
        var currentPages: [PDFPage] = []
        var partNumber = 1
        
        let baseName = url.deletingPathExtension().lastPathComponent
        let totalPages = pdfDocument.pageCount
        
        for i in 0..<totalPages {
            guard let page = pdfDocument.page(at: i) else { continue }
            currentPages.append(page)
            
            if currentPages.count % 5 == 0 || i == totalPages - 1 {
                let tempPDF = PDFDocument()
                for (index, p) in currentPages.enumerated() {
                    tempPDF.insert(p, at: index)
                }
                
                let tempURL = pdfDirectory.appendingPathComponent("temp_check.pdf")
                tempPDF.write(to: tempURL)
                
                let size = (try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
                try? fileManager.removeItem(at: tempURL)
                
                if size > maxBytes && currentPages.count > 1 {
                    let partPDF = PDFDocument()
                    let pagesToSave = Array(currentPages.dropLast())
                    for (index, p) in pagesToSave.enumerated() {
                        partPDF.insert(p, at: index)
                    }
                    
                    let partURL = pdfDirectory.appendingPathComponent("\(baseName)_Part\(partNumber).pdf")
                    partPDF.write(to: partURL)
                    parts.append(partURL)
                    partNumber += 1
                    
                    currentPages = [currentPages.last!]
                }
            }
            
            progressHandler(Double(i + 1) / Double(totalPages))
        }
        
        if !currentPages.isEmpty {
            let partPDF = PDFDocument()
            for (index, p) in currentPages.enumerated() {
                partPDF.insert(p, at: index)
            }
            
            let partURL = pdfDirectory.appendingPathComponent("\(baseName)_Part\(partNumber).pdf")
            partPDF.write(to: partURL)
            parts.append(partURL)
        }
        
        return parts
    }
    
    // MARK: - Private Methods
    
    private func extractImages(from archiveURL: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }
        
        let ext = archiveURL.pathExtension.lowercased()
        
        if ext == "cbz" || ext == "zip" {
            return try await extractZipImages(from: archiveURL, to: tempDirectory, progressHandler: progressHandler)
        } else if ext == "cbr" || ext == "rar" {
            // Try ZIP extraction first (some CBR files are actually ZIP)
            do {
                return try await extractZipImages(from: archiveURL, to: tempDirectory, progressHandler: progressHandler)
            } catch {
                throw ConversionError.rarNotSupported
            }
        } else {
            throw ConversionError.unsupportedFormat
        }
    }
    
    private func extractZipImages(from zipURL: URL, to destination: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        var images: [UIImage] = []
        
        let tempZip = destination.appendingPathComponent("archive.zip")
        try fileManager.copyItem(at: zipURL, to: tempZip)
        
        let extractedDir = destination.appendingPathComponent("extracted")
        try fileManager.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        
        // Extract ZIP contents
        let data = try Data(contentsOf: tempZip)
        try extractZIPContents(data: data, to: extractedDir)
        
        // Find and load images
        let imageURLs = try findImageFiles(in: extractedDir)
        let sortedURLs = imageURLs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        for (index, imageURL) in sortedURLs.enumerated() {
            if let image = UIImage(contentsOfFile: imageURL.path) {
                if let compressedData = image.jpegData(compressionQuality: imageQuality),
                   let compressedImage = UIImage(data: compressedData) {
                    images.append(compressedImage)
                } else {
                    images.append(image)
                }
            }
            progressHandler(Double(index + 1) / Double(sortedURLs.count))
        }
        
        return images
    }
    
    private func extractZIPContents(data: Data, to destinationURL: URL) throws {
        var offset = 0
        let bytes = [UInt8](data)
        
        while offset < bytes.count - 4 {
            // Look for local file header signature (0x04034b50)
            if bytes[offset] == 0x50 && bytes[offset + 1] == 0x4b &&
               bytes[offset + 2] == 0x03 && bytes[offset + 3] == 0x04 {
                
                let compressionMethod = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)
                let compressedSize = UInt32(bytes[offset + 18]) | (UInt32(bytes[offset + 19]) << 8) |
                                    (UInt32(bytes[offset + 20]) << 16) | (UInt32(bytes[offset + 21]) << 24)
                let uncompressedSize = UInt32(bytes[offset + 22]) | (UInt32(bytes[offset + 23]) << 8) |
                                       (UInt32(bytes[offset + 24]) << 16) | (UInt32(bytes[offset + 25]) << 24)
                let fileNameLength = Int(UInt16(bytes[offset + 26]) | (UInt16(bytes[offset + 27]) << 8))
                let extraFieldLength = Int(UInt16(bytes[offset + 28]) | (UInt16(bytes[offset + 29]) << 8))
                
                let fileNameStart = offset + 30
                let fileNameEnd = fileNameStart + fileNameLength
                
                guard fileNameEnd <= bytes.count else { break }
                
                let fileNameBytes = Array(bytes[fileNameStart..<fileNameEnd])
                guard let fileName = String(bytes: fileNameBytes, encoding: .utf8) else {
                    offset += 1
                    continue
                }
                
                let dataStart = fileNameEnd + extraFieldLength
                let dataEnd = dataStart + Int(compressionMethod == 0 ? uncompressedSize : compressedSize)
                
                guard dataEnd <= bytes.count else { break }
                
                if !fileName.hasSuffix("/") {
                    let fileData: Data
                    
                    if compressionMethod == 0 {
                        fileData = Data(bytes[dataStart..<dataEnd])
                    } else if compressionMethod == 8 {
                        let compressedData = Data(bytes[dataStart..<dataEnd])
                        if let decompressed = decompressDeflate(compressedData) {
                            fileData = decompressed
                        } else {
                            offset = dataEnd
                            continue
                        }
                    } else {
                        offset = dataEnd
                        continue
                    }
                    
                    let filePath = destinationURL.appendingPathComponent(fileName)
                    try fileManager.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileData.write(to: filePath)
                }
                
                offset = dataEnd
            } else {
                offset += 1
            }
        }
    }
    
    private func decompressDeflate(_ data: Data) -> Data? {
        let destinationBufferSize = 65536 * 4
        var decompressedData = Data()
        
        let sourceBuffer = [UInt8](data)
        var destinationBuffer = [UInt8](repeating: 0, count: destinationBufferSize)
        
        let status = sourceBuffer.withUnsafeBufferPointer { sourcePtr in
            destinationBuffer.withUnsafeMutableBufferPointer { destPtr in
                compression_decode_buffer(
                    destPtr.baseAddress!, destinationBufferSize,
                    sourcePtr.baseAddress!, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        
        if status > 0 {
            decompressedData.append(contentsOf: destinationBuffer.prefix(status))
            return decompressedData
        }
        
        return nil
    }
    
    private func findImageFiles(in directory: URL) throws -> [URL] {
        var imageURLs: [URL] = []
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"]
        
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        
        for url in contents {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            
            if isDirectory.boolValue {
                imageURLs.append(contentsOf: try findImageFiles(in: url))
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                imageURLs.append(url)
            }
        }
        
        return imageURLs
    }
    
    private func createPDF(from images: [UIImage], outputURL: URL, progressHandler: @escaping (Double) -> Void) async throws {
        let pdfDocument = PDFDocument()
        
        for (index, image) in images.enumerated() {
            autoreleasepool {
                if let pdfPage = PDFPage(image: image) {
                    pdfDocument.insert(pdfPage, at: index)
                }
            }
            progressHandler(Double(index + 1) / Double(images.count))
        }
        
        guard pdfDocument.pageCount > 0 else {
            throw ConversionError.pdfCreationFailed
        }
        
        pdfDocument.write(to: outputURL)
    }
    
    private func loadSavedPDFs() {
        if let data = UserDefaults.standard.data(forKey: "convertedPDFs"),
           let pdfs = try? JSONDecoder().decode([ConvertedPDF].self, from: data) {
            convertedPDFs = pdfs.filter { fileManager.fileExists(atPath: $0.url.path) }
        }
    }
    
    private func savePDFList() {
        if let data = try? JSONEncoder().encode(convertedPDFs) {
            UserDefaults.standard.set(data, forKey: "convertedPDFs")
        }
    }
}

// MARK: - Errors

enum ConversionError: LocalizedError {
    case noImagesFound
    case unsupportedFormat
    case pdfCreationFailed
    case invalidArchive
    case decompressionFailed
    case rarNotSupported
    
    var errorDescription: String? {
        switch self {
        case .noImagesFound:
            return "No images found in the archive"
        case .unsupportedFormat:
            return "Unsupported archive format"
        case .pdfCreationFailed:
            return "Failed to create PDF"
        case .invalidArchive:
            return "Invalid or corrupted archive"
        case .decompressionFailed:
            return "Failed to decompress archive"
        case .rarNotSupported:
            return "RAR format requires additional libraries. Try using CBZ format instead."
        }
    }
}
