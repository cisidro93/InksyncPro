import Foundation
import SwiftUI
import ZIPFoundation

struct ZipUtilities {
    
    static func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let fileManager = FileManager.default
        
        // 1. Security Access (Crucial for files from iCloud/Files app)
        let secure = sourceURL.startAccessingSecurityScopedResource()
        defer { if secure { sourceURL.stopAccessingSecurityScopedResource() } }
        
        // 2. Setup Paths
        let filename = sourceURL.deletingPathExtension().lastPathComponent
        // Use a unique ID to prevent conflicts with old sessions
        let uniqueID = UUID().uuidString.prefix(8)
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("extract_\(filename)_\(uniqueID)")
        
        // 3. Create Directory
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 4. Open Archive (Assumes ZIPFoundation or similar)
        // We use try? to handle potential initialization errors gracefully
        guard let archive = try? Archive(url: sourceURL, accessMode: .read) else {
            throw NSError(domain: "ZipError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
        }
        
        var extractedFiles: [URL] = []
        
        // 5. Iterate with Safety Checks
        for (index, entry) in archive.enumerated() {
            
            // ✅ CHECK 1: Cooperative Cancellation
            // If the user closed the view, STOP immediately.
            try Task.checkCancellation()
            
            // ✅ CHECK 2: Directory Existence
            // If endSession() deleted the folder, STOP immediately.
            if !fileManager.fileExists(atPath: tempDir.path) {
                print("⚠️ Extraction folder vanished. Stopping.")
                throw CancellationError()
            }
            
            // Memory Cleanup
            try autoreleasepool {
                let path = entry.path
                if path.contains("__MACOSX") || path.hasPrefix(".") { return }
                
                let destinationURL = tempDir.appendingPathComponent(path)
                
                // Extract
                _ = try archive.extract(entry, to: destinationURL)
                
                if isImageFile(url: destinationURL) {
                    extractedFiles.append(destinationURL)
                }
            }
            
            // ✅ CHECK 3: Throttle (Optional but Recommended)
            // Give the CPU a tiny breather every 10 files to prevent thermal throttling/watchdog kills
            if index % 10 == 0 {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms sleep
            }
        }
        
        let sortedURLs = extractedFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        
        return (tempDir, sortedURLs)
    }
    
    private static func isImageFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext)
    }
}
