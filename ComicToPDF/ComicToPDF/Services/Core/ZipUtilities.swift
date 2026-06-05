import Foundation
import SwiftUI
import ZIPFoundation
import PDFKit
import Unrar

struct ZipUtilities {
    
    /// Extract all image files from a comic archive (CBZ/ZIP/PDF/CBR/CBT).
    ///
    /// **Security scope contract**: The CALLER is responsible for calling
    /// `startAccessingSecurityScopedResource()` on `sourceURL` before invoking
    /// this function, and `stopAccessingSecurityScopedResource()` after it returns.
    /// This function does NOT open the scope itself to prevent double-open ref-count
    /// bugs when callers already hold the scope.
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

                    // Security scope is managed by the CALLER — do not open it here.
                    // See doc comment on extractComic for the ownership contract.

                    let filename = sourceURL.deletingPathExtension().lastPathComponent
                    let uniqueID = UUID().uuidString.prefix(8)
                    let tempDir = fileManager.temporaryDirectory.appendingPathComponent("extract_\(filename)_\(uniqueID)")
                    
                    // 2. Create Target Directory
                    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    var extractedFiles: [URL] = []
                    
                    // 3. Extraction Strategy
                    if ext == "pdf" {
                        // --- PDF PATH ---
                        let images = try ConcurrencyLocks.pdfLock.withLock { () throws -> [UIImage] in
                            guard let document = PDFDocument(url: sourceURL) else { return [] }
                            let pageCount = document.pageCount
                            var rendered: [UIImage] = []
                            for i in 0..<pageCount {
                                try autoreleasepool {
                                    if let page = document.page(at: i) {
                                        // Render full page
                                        var pageRect = page.bounds(for: .mediaBox)
                                        if pageRect.width <= 0 || pageRect.height <= 0 || pageRect.width.isNaN || pageRect.height.isNaN {
                                            pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
                                        }
                                        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
                                        let image = renderer.image { ctx in
                                            UIColor.white.set()
                                            ctx.fill(pageRect)
                                            ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                                            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                                            page.draw(with: .mediaBox, to: ctx.cgContext)
                                        }
                                        rendered.append(image)
                                    }
                                }
                            }
                            return rendered
                        }
                        
                        for (i, image) in images.enumerated() {
                            try autoreleasepool {
                                let pageName = String(format: "%04d.jpg", i)
                                let fileURL = tempDir.appendingPathComponent(pageName)
                                if let data = image.jpegData(compressionQuality: 0.9) {
                                    try data.write(to: fileURL)
                                    extractedFiles.append(fileURL)
                                }
                            }
                        }
                    } else {
                        // --- ZIP / CBZ PATH ---
                        //
                        // ZIPFoundation.Archive is NOT thread-safe when SHARED across threads.
                        // However, opening N *independent* Archive instances on the same file
                        // is completely safe — each gets its own POSIX file descriptor and its
                        // own internal read/seek position. ZIPFoundation also builds a
                        // pathToEntryMapping [String:Entry] dictionary at init time, so
                        // `archive[path]` is an O(1) lookup per worker with no shared state.
                        //
                        // Strategy:
                        //   Phase 1 — Serial: open one Archive, enumerate qualifying entry
                        //             paths into an array. No image data is loaded into memory.
                        //   Phase 2 — Parallel: split paths into N chunks (N = active CPU count,
                        //             capped at 4). Each chunk worker opens its OWN Archive
                        //             instance, looks up its assigned paths in O(1), and streams
                        //             each entry directly to disk via extract(entry:to:).
                        //             Peak memory = O(1 decompressed image) per worker, not
                        //             O(all images) — eliminates the iOS memory pressure crash.

                        // ── Phase 1: Enumerate qualifying entry paths (no I/O, metadata only) ──
                        guard let enumerationArchive = ZIPFoundation.Archive(url: sourceURL, accessMode: .read) else {
                            throw NSError(domain: "ZipError", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey:
                                            "Could not open CBZ archive '\(sourceURL.lastPathComponent)'"])
                        }

                        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                        var qualifiedPaths: [String] = []

                        for entry in enumerationArchive {
                            let path = entry.path
                            let filename = (path as NSString).lastPathComponent
                            guard !path.contains("__MACOSX"),
                                  !filename.hasPrefix("._"),
                                  filename != ".DS_Store",
                                  !path.hasSuffix("/") else { continue }
                            let fileExt = (filename as NSString).pathExtension.lowercased()
                            guard imageExtensions.contains(fileExt) else { continue }
                            qualifiedPaths.append(path)
                        }

                        guard !qualifiedPaths.isEmpty else {
                            throw NSError(domain: "ZipError", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey:
                                            "No image entries found in '\(sourceURL.lastPathComponent)'"])
                        }

                        // ── Phase 2: N-archive parallel decompression + streaming disk write ──
                        // Cap at 4 to avoid thermal throttling on iOS devices.
                        let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
                        let chunkSize = max(1, Int(ceil(Double(qualifiedPaths.count) / Double(concurrency))))
                        let chunks = stride(from: 0, to: qualifiedPaths.count, by: chunkSize)
                            .map { Array(qualifiedPaths[$0 ..< min($0 + chunkSize, qualifiedPaths.count)]) }

                        // Serial queue guards appends to extractedFiles from concurrent workers.
                        let appendQueue = DispatchQueue(label: "inksync.zip.append")
                        let workerGroup = DispatchGroup()

                        for chunk in chunks {
                            workerGroup.enter()
                            DispatchQueue.global(qos: .userInitiated).async {
                                defer { workerGroup.leave() }

                                // Each worker opens its own Archive — independent file handle & position.
                                guard let workerArchive = ZIPFoundation.Archive(
                                    url: sourceURL, accessMode: .read
                                ) else {
                                    Logger.shared.log(
                                        "ZipUtilities: worker failed to open archive \(sourceURL.lastPathComponent)",
                                        category: "System", type: .warning
                                    )
                                    return
                                }

                                for path in chunk {
                                    autoreleasepool {
                                        // O(1) lookup via ZIPFoundation's internal pathToEntryMapping dict.
                                        guard let entry = workerArchive[path] else { return }

                                        let destinationURL = tempDir.appendingPathComponent(path)
                                        let parentDir = destinationURL.deletingLastPathComponent()

                                        // createDirectory(withIntermediateDirectories:) is idempotent
                                        // and safe to call concurrently from multiple threads.
                                        // Use FileManager.default inline to avoid capturing the non-Sendable
                                        // local `fileManager` reference across isolation boundaries.
                                        try? FileManager.default.createDirectory(
                                            at: parentDir, withIntermediateDirectories: true
                                        )

                                        // stream entry directly to disk — no intermediate Data buffer.
                                        do {
                                            _ = try workerArchive.extract(entry, to: destinationURL)
                                            appendQueue.sync { extractedFiles.append(destinationURL) }
                                        } catch {
                                            Logger.shared.log(
                                                "ZipUtilities: failed to extract \(path): \(error.localizedDescription)",
                                                category: "System", type: .warning
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        workerGroup.wait()
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

    static func listComicEntries(from sourceURL: URL) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let secure = sourceURL.startAccessingSecurityScopedResource()
                    defer { if secure { sourceURL.stopAccessingSecurityScopedResource() } }
                    
                    guard let archive = Archive(url: sourceURL, accessMode: .read) else {
                        throw NSError(domain: "ZipError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read archive"])
                    }
                    let entries = archive.filter { entry in
                        let name = entry.path
                        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                        let filename = URL(fileURLWithPath: name).lastPathComponent
                        return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext)
                            && !name.contains("__MACOSX")
                            && !filename.hasPrefix("._")
                            && filename != ".DS_Store"
                            && !name.hasSuffix("/")
                    }.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                    let virtualURLs = entries.map { sourceURL.appendingPathComponent($0.path) }
                    continuation.resume(returning: virtualURLs)
                } catch {
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
                    guard let archive = Archive(url: destinationURL, accessMode: .create) else {
                        throw NSError(domain: "ZipError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create archive"])
                    }
                    
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
