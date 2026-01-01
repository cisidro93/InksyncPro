import UIKit
import ZIPFoundation

class CBZToEPUBConverter {
    
    struct ConversionOptions {
        let compressionQuality: Double
        let targetSize: CGSize?
        let customScale: Double
        let title: String
    }
    
    func convertCBZToEPUB(_ cbzURL: URL, options: ConversionOptions) async throws -> URL {
        // 1. Extract CBZ
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        print("📦 Extracting CBZ...")
        try FileManager.default.unzipItem(at: cbzURL, to: tempDir)
        
        // 2. Get comic pages (URLs) in order
        let pageURLs = try self.extractComicPageURLs(from: tempDir)
        print("📄 Found \(pageURLs.count) pages")
        
        if pageURLs.isEmpty {
            throw NSError(domain: "CBZConversion", code: 404, userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ"])
        }
        
        // 3. Use EPUBGenerator
        // Determine smart passthrough
        // If High Quality (1.0), No Target Size, and No Custom Scale -> Passthrough (Copy only)
        let shouldPassthrough = options.compressionQuality >= 0.99 &&
                                options.targetSize == nil &&
                                (options.customScale >= 0.99 || options.customScale <= 0.0)
        
        let metadata = PDFMetadata(title: options.title, author: "Unknown")
        let generator = EPUBGenerator(
            settings: EPUBSettings(),
            metadata: metadata,
            compressionQuality: options.compressionQuality,
            targetSize: options.targetSize,
            customScale: options.customScale
        )
        
        // Generator is marked async, so we just await it directly
        let (epubURL, _) = try await generator.generateEPUB(from: pageURLs, outputName: options.title, passthrough: shouldPassthrough)

        generator.printCompressionStats()
        print("✅ EPUB created via Generator: \(epubURL.lastPathComponent)")
        
        return epubURL
    }
    
    // Extract comic pages as URLs
    private func extractComicPageURLs(from directory: URL) throws -> [URL] {
        var imageUrls: [URL] = []
        
        if let deepEnumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in deepEnumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                    imageUrls.append(fileURL)
                }
            }
        }
        
        // Sort by filename to maintain page order
        imageUrls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        return imageUrls
    }
}
