import Foundation
import SwiftUI
import ZIPFoundation

struct ZipUtilities {
    
    /// Extracts a comic safely using aggressive memory cleanup to prevent crashes.
    /// Returns the directory URL and a list of sorted image URLs.
    static func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        
        // 1. Setup paths
        let fileManager = FileManager.default
        // let filename = sourceURL.deletingPathExtension().lastPathComponent
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("extract_\(UUID().uuidString)")
        
        // 2. Create directory
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 3. Unzip Logic (Running on background thread via Task.detached in ConversionManager)
        // We use try? to handle potential initialization errors gracefully
        guard let archive = try? Archive(url: sourceURL, accessMode: .read) else {
            throw NSError(domain: "ZipError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
        }
        
        var extractedFiles: [URL] = []
        
        // 4. Iterate and Extract with Autoreleasepool
        for entry in archive {
            // ✅ CRITICAL FIX: autoreleasepool forces memory cleanup after EACH file
            // This prevents RAM from spiking to 2GB+ during extraction
            try autoreleasepool {
                let path = entry.path
                // Filter out macOS metadata files that often cause issues
                if path.contains("__MACOSX") || path.hasPrefix(".") { return }
                
                let destinationURL = tempDir.appendingPathComponent(path)
                
                // Extract
                _ = try archive.extract(entry, to: destinationURL)
                
                // Verify it's an image
                if isImageFile(url: destinationURL) {
                    extractedFiles.append(destinationURL)
                }
            }
        }
        
        // 5. Sort naturally (Page 1, Page 2, Page 10...)
        let sortedURLs = extractedFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        
        print("✅ Unzipped \(sortedURLs.count) pages to \(tempDir.path)")
        return (tempDir, sortedURLs)
    }
    
    private static func isImageFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext)
    }
}
