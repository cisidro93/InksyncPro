import Foundation
import ZIPFoundation

struct ZipUtilities {
    
    // ✅ SURGICAL EXTRACTION
    // Safe, Memory-Efficient, Error-Tolerant
    static func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        return try await Task.detached(priority: .utility) { // Lower priority to prevent UI freeze
            let fileManager = FileManager.default
            
            // 1. Sanity Check: Does the file actually exist?
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw NSError(domain: "ZipUtilities", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source file not found at path: \(sourceURL.path)"])
            }
            
            // 2. Setup Temp Directory
            let uniqueID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("Editor_\(uniqueID)")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // 3. Open Archive (Read-Only)
            // We use 'guard' here so if the header is corrupt, we catch it gracefully.
            guard let archive = try? Archive(url: sourceURL, accessMode: .read) else {
                throw NSError(domain: "ZipUtilities", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to read archive header. File may be corrupted or encrypted."])
            }
            
            var extractedURLs: [URL] = []
            let validExts = ["jpg", "jpeg", "png", "webp"]
            
            // 4. Iterate and Extract One-by-One
            for entry in archive {
                let path = entry.path
                let ext = (path as NSString).pathExtension.lowercased()
                let filename = (path as NSString).lastPathComponent
                
                // Strict Filter: Ignore __MACOSX, hidden files, and non-images
                if validExts.contains(ext) && !path.contains("__MACOSX") && !filename.hasPrefix(".") {
                    let destURL = tempDir.appendingPathComponent(filename)
                    
                    do {
                        // Extract single file
                        _ = try archive.extract(entry, to: destURL)
                        extractedURLs.append(destURL)
                    } catch {
                        print("⚠️ Warning: Failed to extract \(filename). Skipping.")
                        // We CONTINUE instead of crashing
                    }
                }
            }
            
            // 5. Final Check
            if extractedURLs.isEmpty {
                throw NSError(domain: "ZipUtilities", code: 2, userInfo: [NSLocalizedDescriptionKey: "Extraction complete, but no valid images were found."])
            }
            
            // 6. Sort Alphabetically
            extractedURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
            
            return (tempDir, extractedURLs)
        }.value
    }
}
