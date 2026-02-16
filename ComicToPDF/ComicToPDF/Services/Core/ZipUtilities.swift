import Foundation
import SwiftUI
import ZIPFoundation
import PDFKit // ✅ NEW

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
                    
                    let ext = sourceURL.pathExtension.lowercased()
                    var extractedFiles: [URL] = []
                    
                    // 3. Extraction Strategy
                    if ext == "pdf" {
                        // --- PDF PATH ---
                        if let document = PDFDocument(url: sourceURL) {
                            let pageCount = document.pageCount
                            for i in 0..<pageCount {
                                if let page = document.page(at: i) {
                                    // Render full page
                                    let pageRect = page.bounds(for: .mediaBox)
                                    let renderer = UIGraphicsImageRenderer(size: pageRect.size)
                                    let image = renderer.image { ctx in
                                        UIColor.white.set()
                                        ctx.fill(pageRect)
                                        ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                                        ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                                        page.draw(with: .mediaBox, to: ctx.cgContext)
                                    }
                                    
                                    // Save
                                    let pageName = String(format: "%04d.jpg", i)
                                    let fileURL = tempDir.appendingPathComponent(pageName)
                                    if let data = image.jpegData(compressionQuality: 0.9) {
                                        try data.write(to: fileURL)
                                        extractedFiles.append(fileURL)
                                    }
                                }
                            }
                        }
                    } else if ["cbr", "rar"].contains(ext) {
                        // --- RAR / CBR PATH ---
                        let archive = try UnrarKit.Archive(url: sourceURL)
                        try archive.extractFiles(to: tempDir)
                        
                        // Enumerate extracted files
                        let keys: [URLResourceKey] = [.isRegularFileKey]
                        let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: keys)
                        
                        while let fileURL = enumerator?.nextObject() as? URL {
                             let fileExt = fileURL.pathExtension.lowercased()
                             if ["jpg", "jpeg", "png", "webp", "gif"].contains(fileExt) {
                                  extractedFiles.append(fileURL)
                             }
                        }
                        
                    } else {
                        // --- ZIP / CBZ PATH (Legacy) ---
                        // Initialize Archive
                        guard let archive = try? ZIPFoundation.Archive(url: sourceURL, accessMode: .read) else {
                            throw NSError(domain: "ZipError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open archive"])
                        }
                        
                        // Iterate
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
                                let fileExt = destinationURL.pathExtension.lowercased()
                                if ["jpg", "jpeg", "png", "webp", "gif"].contains(fileExt) {
                                    extractedFiles.append(destinationURL)
                                }
                            }
                        }
                    }

                    // 5. Sort and Finish
                    let sortedURLs = extractedFiles.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                    
                    print("✅ Successfully unpacked \(sortedURLs.count) files.")
                    continuation.resume(returning: (tempDir, sortedURLs))
                    
                } catch {
                    print("❌ Crash/Error in ZipUtilities: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Zips a directory into a single archive file
    /// - Parameters:
    ///   - sourceURL: The directory to zip
    ///   - destinationURL: The destination URL for the zip file
    static func zipDirectory(_ sourceURL: URL, to destinationURL: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fileManager = FileManager.default
                    
                    // Remove existing file if present
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    
                    // Creates a new archive at destinationURL
                    guard let archive = try? Archive(url: destinationURL, accessMode: .create) else {
                        throw NSError(domain: "ZipError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create archive at \(destinationURL.path)"])
                    }
                    
                    // Get all files in source directory
                    let fileURLs = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
                    
                    for fileURL in fileURLs {
                        let fileName = fileURL.lastPathComponent
                        // Skip hidden system files
                        if fileName.hasPrefix(".") || fileName == "__MACOSX" { continue }
                        
                        try archive.addEntry(with: fileName, relativeTo: sourceURL)
                    }
                    
                    print("✅ Successfully zipped to \(destinationURL.lastPathComponent)")
                    continuation.resume()
                    
                } catch {
                    print("❌ Zipping failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
