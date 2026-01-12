import Foundation
import SwiftUI
import ZIPFoundation

struct ZipUtilities {
    
    static func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        return try await withCheckedThrowingContinuation { continuation in
            // Use a raw background queue to guarantee isolation from the UI
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fileManager = FileManager.default
                    
                    // 1. Security & Setup
                    let secure = sourceURL.startAccessingSecurityScopedResource()
                    defer { if secure { sourceURL.stopAccessingSecurityScopedResource() } }
                    
                    let filename = sourceURL.deletingPathExtension().lastPathComponent
                    let uniqueID = UUID().uuidString.prefix(8)
                    let tempDir = fileManager.temporaryDirectory.appendingPathComponent("extract_\(filename)_\(uniqueID)")
                    
                    // 2. Create Target Directory
                    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    // 3. Initialize Archive
                    guard let archive = try? Archive(url: sourceURL, accessMode: .read, preferredEncoding: nil) else {
                        throw NSError(domain: "ZipError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
                    }
                    
                    var extractedFiles: [URL] = []
                    
                    // 4. Iterate with "Breathing Room"
                    for entry in archive {
                        // FORCE MEMORY CLEANUP
                        try autoreleasepool {
                            let path = entry.path
                            // Skip macOS hidden files and folders
                            if path.contains("__MACOSX") || path.hasPrefix(".") || path.hasSuffix("/") { return }
                            
                            let destinationURL = tempDir.appendingPathComponent(path)
                            
                            // Extract file
                            _ = try archive.extract(entry, to: destinationURL)
                            
                            // Validate it is an image
                            let ext = destinationURL.pathExtension.lowercased()
                            if ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) {
                                extractedFiles.append(destinationURL)
                            }
                        }
                        
                        // ✅ CRITICAL SAFETY PAUSE: Sleep for 5ms to let memory clear
                        // This prevents the "Watchdog" from killing the app
                        usleep(5000) 
                    }
                    
                    // 5. Sort and Finish
                    let sortedURLs = extractedFiles.sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }
                    
                    print("✅ Successfully unzipped \(sortedURLs.count) files.")
                    continuation.resume(returning: (tempDir, sortedURLs))
                    
                } catch {
                    print("❌ Crash/Error in ZipUtilities: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
