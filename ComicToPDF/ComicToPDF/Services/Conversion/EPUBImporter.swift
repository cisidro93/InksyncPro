import Foundation
import UIKit
import ZIPFoundation

/// Helper class to handle EPUB extraction and image normalization
class EPUBImporter {
    
    enum ImportError: LocalizedError {
        case fileNotFound
        case unzipFailed
        case noImagesFound
        
        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "EPUB file not found"
            case .unzipFailed: return "Failed to unzip EPUB"
            case .noImagesFound: return "No images found in EPUB"
            }
        }
    }
    
    /// Extract images from EPUB to a simplified CBZ-ready structure
    /// - Parameters:
    ///   - epubURL: Source EPUB
    ///   - targetDir: Directory where flattened images will be placed
    static func extractImages(from epubURL: URL, to targetDir: URL) throws -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // 1. Unzip
        do {
            try FileManager.default.unzipItem(at: epubURL, to: tempDir)
        } catch {
            throw ImportError.unzipFailed
        }
        
        // 2. Find Images (Recursive)
        var imageURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                    // Filter out unlikely candidates (thumbnails, icons)
                    if fileURL.lastPathComponent.contains("cover") {
                        // Keep covers, but maybe rename? Logic depends on preference.
                    }
                    imageURLs.append(fileURL)
                }
            }
        }
        
        guard !imageURLs.isEmpty else {
            throw ImportError.noImagesFound
        }
        
        // 3. Sort
        // Try to respect OEBPS structure if possible, otherwise alpha sort
        // Heuristic: If files are in OEBPS/images, alpha sort usually works for standardized EPUBs.
        imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        // 4. Flatten to Target
        var consolidatedURLs: [URL] = []
        for (index, srcURL) in imageURLs.enumerated() {
            let ext = srcURL.pathExtension
            // Normalized name: page_001.jpg
            let newName = String(format: "page_%04d.%@", index + 1, ext)
            let destURL = targetDir.appendingPathComponent(newName)
            
            try FileManager.default.copyItem(at: srcURL, to: destURL)
            consolidatedURLs.append(destURL)
        }
        
        Logger.shared.log("Extracted \(consolidatedURLs.count) images from EPUB", category: "Import", type: .success)
        return consolidatedURLs
    }
}
