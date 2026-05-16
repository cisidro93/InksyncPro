import Foundation
import SwiftUI
import ZIPFoundation
import PDFKit
import Unrar

struct ZipUtilities {
    
    static func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let ext = sourceURL.pathExtension.lowercased()

        // Delegate CBR/RAR directly to the dedicated extractor
        if ["cbr", "rar"].contains(ext) {
            return try await CBRExtractor.extract(from: sourceURL)
        }

        // Delegate CBT (Comic Book TAR) to the dedicated extractor
        if ["cbt", "tar"].contains(ext) {
            return try await CBTExtractor.extract(from: sourceURL)
        }

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
                    
                    var extractedFiles: [URL] = []
                    
                    // 3. Extraction Strategy
                    if ext == "pdf" {
                        // --- PDF PATH ---
                        if let document = PDFDocument(url: sourceURL) {
                            let pageCount = document.pageCount
                            for i in 0..<pageCount {
                                try autoreleasepool {
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
                        }

                    } else {
                        // --- ZIP / CBZ PATH ---
                        // Restore stable-build approach: failable initializer + full internal entry path.
                        // ZIPFoundation.extract(entry:to:) creates parent directories automatically (v0.9.9+).
                        // We add an explicit createDirectory before each extract as belt-and-suspenders.
                        guard let archive = ZIPFoundation.Archive(url: sourceURL, accessMode: .read) else {
                            throw NSError(domain: "ZipError", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Could not open CBZ archive at \(sourceURL.lastPathComponent)"])
                        }

                        for entry in archive {
                            try autoreleasepool {
                                let path = entry.path
                                let filename = URL(fileURLWithPath: path).lastPathComponent

                                // Skip macOS hidden files and directories
                                if path.contains("__MACOSX") || filename.hasPrefix("._") || filename == ".DS_Store" || path.hasSuffix("/") { return }

                                let destinationURL = tempDir.appendingPathComponent(path)

                                // ✅ Defensive: ensure parent directory exists before extracting.
                                // ZIPFoundation does this internally, but we do it explicitly for safety.
                                let parentDir = destinationURL.deletingLastPathComponent()
                                if !fileManager.fileExists(atPath: parentDir.path) {
                                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                                }

                                _ = try archive.extract(entry, to: destinationURL)

                                // Validate it is a supported image format
                                let fileExt = destinationURL.pathExtension.lowercased()
                                if ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(fileExt) {
                                    extractedFiles.append(destinationURL)
                                }
                            }
                        }
                    }

                    // 5. Sort and Finish
                    let sortedURLs = extractedFiles.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                    
                    Logger.shared.log("Successfully unpacked \(sortedURLs.count) files", category: "System", type: .success)
                    continuation.resume(returning: (tempDir, sortedURLs))
                    
                } catch {
                    Logger.shared.log("Crash/Error in ZipUtilities: \(error.localizedDescription)", category: "System", type: .error)
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
                    let archive = try Archive(url: destinationURL, accessMode: .create)
                    
                    // Get all files in source directory
                    let fileURLs = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
                    
                    for fileURL in fileURLs {
                        let fileName = fileURL.lastPathComponent
                        // Skip hidden system files
                        if fileName.hasPrefix("._") || fileName == ".DS_Store" || fileName == "__MACOSX" { continue }
                        
                        try archive.addEntry(with: fileName, relativeTo: sourceURL)
                    }
                    
                    Logger.shared.log("Successfully zipped to \(destinationURL.lastPathComponent)", category: "System", type: .success)
                    continuation.resume()
                    
                } catch {
                    Logger.shared.log("Zipping failed: \(error.localizedDescription)", category: "System", type: .error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
