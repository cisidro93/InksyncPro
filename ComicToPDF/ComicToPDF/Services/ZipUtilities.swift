import Foundation
import ZIPFoundation

struct ZipUtilities {
    
    // ✅ SURGICAL EXTRACTION
    // Safe, Memory-Efficient, Error-Tolerant, with Debug Logging
    static func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        print("📂 ZipUtilities: Starting extraction for \(sourceURL.lastPathComponent)")
        
        return try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            
            // 1. Sanity Check
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                print("❌ ZipUtilities: Source file not found!")
                throw NSError(domain: "ZipUtilities", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source file not found"])
            }
            
            // 2. Setup Temp Directory
            let uniqueID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("Editor_\(uniqueID)")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            print("📂 ZipUtilities: Temp dir created at \(tempDir.path)")
            
            // 3. Open Archive
            guard let archive = try? Archive(url: sourceURL, accessMode: .read) else {
                print("❌ ZipUtilities: Failed to open archive header.")
                throw NSError(domain: "ZipUtilities", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to read archive header."])
            }
            
            var extractedURLs: [URL] = []
            let validExts = ["jpg", "jpeg", "png", "webp"]
            
            // 4. Iterate and Extract One-by-One (With Memory Cleanup)
            for entry in archive {
                // ✅ AUTORELEASEPOOL: Crucial for loops performing file I/O
                // This forces iOS to dump memory AFTER EACH FILE, preventing RAM spikes.
                try autoreleasepool {
                    let path = entry.path
                    let ext = (path as NSString).pathExtension.lowercased()
                    let filename = (path as NSString).lastPathComponent
                    
                    if validExts.contains(ext) && !path.contains("__MACOSX") && !filename.hasPrefix(".") {
                        let destURL = tempDir.appendingPathComponent(filename)
                        
                        do {
                            _ = try archive.extract(entry, to: destURL)
                            extractedURLs.append(destURL)
                        } catch {
                            print("⚠️ ZipUtilities: Failed to extract \(filename). Skipping.")
                        }
                    }
                }
            }
            
            print("✅ ZipUtilities: Extraction complete. Found \(extractedURLs.count) images.")
            
            // 5. Final Check
            if extractedURLs.isEmpty {
                // Clean up empty folder before throwing
                try? fileManager.removeItem(at: tempDir)
                throw NSError(domain: "ZipUtilities", code: 2, userInfo: [NSLocalizedDescriptionKey: "No valid images found in archive."])
            }
            
            // 6. Sort Alphabetically
            extractedURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
            
            return (tempDir, extractedURLs)
        }.value
    }
}
