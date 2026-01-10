import Foundation
import ZIPFoundation

enum ZipUtilities {
    /// Extracts a comic file (cbz, cbr, zip, etc.) safely by renaming to .zip and using system unzip.
    /// Returns the temporary directory (which the caller must clean up) and the list of sorted image URLs.
    static func extractComic(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let uniqueID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(uniqueID)
            
            // 1. Create clean directory
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // 2. COPY and RENAME to .zip (Fixes 'Invalid Archive' errors)
            let tempZipURL = fileManager.temporaryDirectory.appendingPathComponent("temp_\(uniqueID).zip")
            if fileManager.fileExists(atPath: tempZipURL.path) { try fileManager.removeItem(at: tempZipURL) }
            try fileManager.copyItem(at: url, to: tempZipURL)
            
            defer { try? fileManager.removeItem(at: tempZipURL) } // Clean up the temp zip
            
            // 3. Unzip Everything
            try fileManager.unzipItem(at: tempZipURL, to: tempDir)
            
            // 4. Filter Results (Post-Process)
            var imageURLs: [URL] = []
            let validExts = ["jpg", "jpeg", "png", "webp"]
            
            if let subPaths = try? fileManager.subpathsOfDirectory(atPath: tempDir.path) {
                let sortedPaths = subPaths.sorted()
                for path in sortedPaths {
                    let ext = (path as NSString).pathExtension.lowercased()
                    let filename = (path as NSString).lastPathComponent
                    
                    // Ignore junk
                    if validExts.contains(ext) && !path.contains("__MACOSX") && !filename.hasPrefix(".") {
                        imageURLs.append(tempDir.appendingPathComponent(path))
                    }
                }
            }
            
            // Ensure strictly sorted
            imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
            
            return (tempDir, imageURLs)
        }.value
    }
}
