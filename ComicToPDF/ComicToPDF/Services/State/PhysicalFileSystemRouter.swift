import Foundation
import UIKit
import SwiftUI
import PDFKit
import ZIPFoundation
import Unrar

/// Safely handles all iOS Storage interactions, including disk persistence, thumbnail caching into Application Support, and atomic NSFileCoordinator bindings independent from the Presentation logic.
@MainActor
class PhysicalFileSystemRouter {
    static let shared = PhysicalFileSystemRouter()
    private init() {}
    
    // MARK: - Core File IO Storage
    nonisolated static func getCoversDirectory() -> URL {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory
        }
        let coversDir = appSupportDir.appendingPathComponent("Covers", isDirectory: true)
        
        if !fileManager.fileExists(atPath: coversDir.path) {
            try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
        }
        return coversDir
    }
    
    func getCoverURL(for pdf: ConvertedPDF) -> URL? {
        if let selectedID = pdf.metadata.selectedCoverID,
           let variantURL = pdf.metadata.coverVariants[selectedID],
           FileManager.default.fileExists(atPath: variantURL.path) {
            return variantURL
        }
        return getOriginalCoverURL(for: pdf)
    }

    func getOriginalCoverURL(for pdf: ConvertedPDF) -> URL {
        let coversDir = Self.getCoversDirectory()
        return coversDir.appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
    }
    
    func migrateCoversToDisk(manager: ConversionManager) {
        var updated = false
        for i in 0..<manager.convertedPDFs.count {
            if let data = manager.convertedPDFs[i].coverImageData {
                if let coverURL = getCoverURL(for: manager.convertedPDFs[i]) {
                    try? data.write(to: coverURL)
                }
                manager.convertedPDFs[i].coverImageData = nil
                updated = true
            }
        }
        if updated { manager.saveLibrary() }
    }
    
    func loadCoverThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) async -> UIImage? {
        let keyStr = pdf.id.uuidString
        if let cached = manager.thumbnailCache.object(forKey: keyStr as NSString) { return cached }
        // ✅ PERF: Resolve cover URL on MainActor *once*, before the background task.
        // Avoids an implicit actor-hop back to MainActor per cell during scroll.
        let coverURL = getCoverURL(for: pdf)
        let coverImageData = pdf.coverImageData
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // 1. Check ultra-fast Daemon cache first
            if let daemonCached = await ThumbnailDaemon.shared.getCachedThumbnail(for: pdf.id) {
                await MainActor.run { manager.thumbnailCache.setObject(daemonCached, forKey: keyStr as NSString) }
                return daemonCached
            }
            
            // 2. Check standard Covers directory using high-performance downsampled ImageIO path
            if let url = coverURL, FileManager.default.fileExists(atPath: url.path) {
                let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                if let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts) {
                    let downsampleOpts = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 200
                    ] as CFDictionary
                    
                    if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts) {
                        let thumbnail = UIImage(cgImage: cg)
                        await MainActor.run { manager.thumbnailCache.setObject(thumbnail, forKey: keyStr as NSString) }
                        return thumbnail
                    }
                }
            }
            
            if let data = coverImageData, let image = UIImage(data: data) { return image }
            return nil
        }.value
    }
    
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF, manager: ConversionManager) {
        guard let coverURL = getCoverURL(for: pdf) else { return }
        try? data.write(to: coverURL)
        
        autoreleasepool {
            if let image = UIImage(data: data) {
                let thumbnail = image.preparingThumbnail(of: CGSize(width: 160, height: 240)) ?? image
                let key = pdf.id.uuidString as NSString
                // Pixel byte count approximation — accurate enough for NSCache pressure, zero CPU overhead.
                let cost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
                manager.thumbnailCache.setObject(thumbnail, forKey: key, cost: cost)
            }
        }
        
        if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs[index].coverImageData = nil
            // Route through the debounced subject so rapid backfill saves coalesce
            // into one SwiftUI diff per 150ms window instead of one per cover write.
            manager.thumbnailReadySubject.send()
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF, manager: ConversionManager) {
        // 1. Remove from UI state instantly for perceived zero-latency
        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
            manager.convertedPDFs.remove(at: idx)
            manager.saveLibrary()
        }
        
        // 2. Offload the heavy file destruction to a background task
        let urlTarget = pdf.url
        let coverTarget = getCoverURL(for: pdf)
        let docName = pdf.name
        
        Task.detached(priority: .background) {
            do {
                if FileManager.default.fileExists(atPath: urlTarget.path) {
                    try FileManager.default.removeItem(at: urlTarget)
                }
                if let coverTarget = coverTarget, FileManager.default.fileExists(atPath: coverTarget.path) {
                    try? FileManager.default.removeItem(at: coverTarget)
                }
                Logger.shared.log("Deleted File and Cover in background: \(docName)", category: "Library")
            } catch {
                Logger.shared.log("Failed to delete file in background: \(error)", category: "Library", type: .error)
            }
        }
    }
    
    // MARK: - Heavy Graphics Generation
    func generateCoverThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) async {
        let variantData: Data? = autoreleasepool {
            if let variantID = pdf.metadata.selectedCoverID,
               let variantURL = pdf.metadata.coverVariants[variantID],
               FileManager.default.fileExists(atPath: variantURL.path),
               let data = try? Data(contentsOf: variantURL),
               let image = UIImage(data: data) {
                return image.jpegData(compressionQuality: 0.7)
            }
            return nil
        }
        
        if let jpegData = variantData {
            saveCoverImage(jpegData, for: pdf, manager: manager)
            return
        }
        
        if let coverURL = getCoverURL(for: pdf), FileManager.default.fileExists(atPath: coverURL.path) { return }
        
        let url: URL
        var needsStopAccess = false
        if case .linked(let bm) = pdf.sourceMode, let resolved = try? BookmarkResolver.shared.resolve(bm) {
            needsStopAccess = resolved.startAccessingSecurityScopedResource()
            url = resolved
        } else if case .cloud = pdf.sourceMode {
            // Cloud files: cover must be generated from a pre-streamed local temp URL.
            // Call generateCoverThumbnailFromLocalURL(for:localURL:manager:) instead.
            return
        } else {
            url = pdf.url
        }
        
        let image = await Task.detached(priority: .background) { () -> UIImage? in
            return PhysicalFileSystemRouter.extractCoverImageStatic(from: url)
        }.value
        
        // Release scope after background work completes.
        if needsStopAccess { url.stopAccessingSecurityScopedResource() }
        
        let jpegData = autoreleasepool {
            image?.jpegData(compressionQuality: 0.7)
        }
        guard let data = jpegData else { return }
        saveCoverImage(data, for: pdf, manager: manager)
    }

    /// Generates and persists a cover thumbnail from an already-downloaded temp file.
    /// Call this immediately after `CloudDownloadManager.streamCloudFile` returns.
    func generateCoverThumbnailFromLocalURL(for pdf: ConvertedPDF, localURL: URL, manager: ConversionManager) async {
        // Skip if cover already exists on disk
        if let coverURL = getCoverURL(for: pdf), FileManager.default.fileExists(atPath: coverURL.path) { return }
        
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            PhysicalFileSystemRouter.extractCoverImageStatic(from: localURL)
        }.value
        
        let jpegData = autoreleasepool {
            image?.jpegData(compressionQuality: 0.7)
        }
        guard let data = jpegData else { return }
        saveCoverImage(data, for: pdf, manager: manager)
        Logger.shared.log("PhysicalFileSystemRouter: Cloud cover generated for '\(pdf.name)'", category: "Cloud", type: .success)
    }

    /// Generates and persists a cover thumbnail from a live CloudPageSource.
    /// Fetches only page 0 via a single HTTP byte-range request — no full archive download.
    func generateCoverFromCloudSource(for pdf: ConvertedPDF, source: CloudPageSource, manager: ConversionManager) async {
        // Skip if cover already exists
        if let coverURL = getCoverURL(for: pdf), FileManager.default.fileExists(atPath: coverURL.path) { return }
        guard let firstEntry = source.pages.first else { return }

        do {
            let data = try await ZipCentralDirectory.fetchEntryData(entry: firstEntry, manifest: source.manifest)
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                UIImage(data: data)
            }.value
            guard let image, let jpegData = image.jpegData(compressionQuality: 0.7) else { return }
            saveCoverImage(jpegData, for: pdf, manager: manager)
            Logger.shared.log("PhysicalFileSystemRouter: Cloud cover from byte-range for '\(pdf.name)'", category: "Cloud", type: .success)
        } catch {
            Logger.shared.log("PhysicalFileSystemRouter: Cloud cover byte-range fetch failed: \(error.localizedDescription)", category: "Cloud", type: .error)
        }
    }
    
    func backfillMissingThumbnails(manager: ConversionManager) {
        let allPDFs = manager.convertedPDFs

        // Pass 1 — warm in-memory NSCache for covers that exist on disk but aren't cached.
        // This is the "cold-start" fix: covers appear immediately on first library open.
        Task(priority: .userInitiated) {
            var warmedAny = false
            for pdf in allPDFs {
                let key = pdf.id.uuidString as NSString
                guard manager.thumbnailCache.object(forKey: key) == nil,
                      let coverURL = getCoverURL(for: pdf),
                      FileManager.default.fileExists(atPath: coverURL.path) else { continue }

                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let src = CGImageSourceCreateWithURL(coverURL as CFURL, srcOpts) else { return nil }
                    let downsampleOpts = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 200
                    ] as CFDictionary
                    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, downsampleOpts) else { return nil }
                    return UIImage(cgImage: cg)
                }.value

                if let image {
                    await MainActor.run {
                        manager.thumbnailCache.setObject(image, forKey: key)
                        warmedAny = true
                    }
                }
            }
            // Signal SwiftUI to re-render cells so they pick up newly-cached covers
            if warmedAny {
                await MainActor.run { manager.objectWillChange.send() }
            }
        }


        // Pass 2 — generate covers for files that have no on-disk cover yet.
        // IMPORTANT: Process in batches of 5 with yield between batches to prevent
        // saturating the NAND / memory bus when importing hundreds of files at once.
        // Without batching, every generateCoverThumbnail runs concurrently via
        // Task.detached which causes OOM crashes on large library imports.
        let pdfsNeedingCovers = allPDFs.filter { pdf in
            guard let coverURL = getCoverURL(for: pdf) else { return true }
            return !FileManager.default.fileExists(atPath: coverURL.path)
        }
        guard !pdfsNeedingCovers.isEmpty else { return }
        Task(priority: .background) {
            let batchSize = 5
            for batchStart in stride(from: 0, to: pdfsNeedingCovers.count, by: batchSize) {
                let batch = pdfsNeedingCovers[batchStart ..< min(batchStart + batchSize, pdfsNeedingCovers.count)]
                for pdf in batch {
                    await generateCoverThumbnail(for: pdf, manager: manager)
                }
                // Yield after each batch so the system can reclaim memory and
                // service other lower-priority tasks (UI, scrolling).
                await Task.yield()
            }
        }

        // Pass 3 — cloud cover extraction for Dropbox files still missing on-disk covers.
        let cloudFilesNeedingCovers = pdfsNeedingCovers.filter {
            if case .cloud = $0.sourceMode { return true }
            return false
        }
        if !cloudFilesNeedingCovers.isEmpty {
            Task(priority: .background) {
                await CloudCoverExtractor.shared.extract(for: cloudFilesNeedingCovers)
            }
        }
    }

    
    func loadThumbnailAsync(for pdf: ConvertedPDF, manager: ConversionManager) async {
        if manager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) != nil { return }
        
        var generatedImage: UIImage? = nil
        if let coverURL = self.getCoverURL(for: pdf) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) {
                let downsampleOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 200
                ] as CFDictionary
                
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
                    generatedImage = UIImage(cgImage: cgImage)
                }
            }
        }
        
        if let image = generatedImage {
            await MainActor.run {
                manager.thumbnailCache.setObject(image, forKey: pdf.id.uuidString as NSString)
                // H2: Fire the debounced subject instead of objectWillChange directly.
                // Up to 200 concurrent cell loads coalesce into one SwiftUI diff per 150ms window.
                manager.thumbnailReadySubject.send()
            }
        } else {
            await self.generateCoverThumbnail(for: pdf, manager: manager)
            if manager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) != nil {
                await MainActor.run { manager.thumbnailReadySubject.send() }
            }
        }
    }
    
    func getThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) -> UIImage? {
        let keyStr = pdf.id.uuidString
        if let cached = manager.thumbnailCache.object(forKey: keyStr as NSString) { return cached }
        
        // Resolve URL and image data on MainActor to prevent background hopping
        let coverURL = getCoverURL(for: pdf)
        let coverImageData = pdf.coverImageData
        
        Task.detached(priority: .userInitiated) {
            var generatedImage: UIImage? = nil
            if let coverURL = coverURL {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                if let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) {
                    let downsampleOptions = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 200
                    ] as CFDictionary
                    
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
                        generatedImage = UIImage(cgImage: cgImage)
                    }
                }
            } else if let data = coverImageData {
                generatedImage = UIImage(data: data)
            }
            
            if let image = generatedImage {
                await MainActor.run {
                    manager.thumbnailCache.setObject(image, forKey: keyStr as NSString)
                    // H2: debounced pulse — prevents 200 per-cell full-tree re-renders during scroll
                    manager.thumbnailReadySubject.send()
                }
            } else {
                await MainActor.run {
                    _ = Task {
                        await self.generateCoverThumbnail(for: pdf, manager: manager)
                    }
                }
            }
        }
        return nil
    }
    
    // MARK: - Native Thread-Safe Physical OS Interactions
    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String, manager: ConversionManager) throws {
        guard let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) else {
            throw NSError(domain: "Database", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found within internal database loop."])
        }
        
        let fileManager = FileManager.default
        let currentURL = pdf.url
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw NSError(domain: "FileSystem", code: 404, userInfo: [NSLocalizedDescriptionKey: "The physical file no longer exists at original path."])
        }
        
        let pathExtension = currentURL.pathExtension
        let cleanName = newName.replacingOccurrences(of: "/", with: "-")
                               .replacingOccurrences(of: "\\", with: "-")
                               .replacingOccurrences(of: ":", with: "-")
        
        let targetDirectory = currentURL.deletingLastPathComponent()
        var newURL = targetDirectory.appendingPathComponent("\(cleanName).\(pathExtension)")
        
        var counter = 2
        while fileManager.fileExists(atPath: newURL.path) {
            let sequencedName = "\(cleanName)_v\(counter).\(pathExtension)"
            newURL = targetDirectory.appendingPathComponent(sequencedName)
            counter += 1
        }
        
        do {
            try fileManager.moveItem(at: currentURL, to: newURL)
        } catch {
            Logger.shared.log("Move Failure: \(error)", category: "FileSystem", type: .error)
            throw error
        }
        
        // ✅ PERF: @MainActor class — direct assignment, no dispatch needed
        manager.convertedPDFs[idx].url = newURL
        manager.convertedPDFs[idx].name = newURL.lastPathComponent
        manager.saveLibrary()
    }
    
    // MARK: - Extracted Static Disk Helpers
    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            return ConcurrencyLocks.pdfLock.withLock {
                guard let document = PDFDocument(url: url) else { return nil }
                
                let drawPage: (PDFPage) -> UIImage? = { page in
                    let pageBounds = page.bounds(for: .mediaBox)
                    guard pageBounds.width > 0 && pageBounds.height > 0 && !pageBounds.width.isNaN && !pageBounds.height.isNaN else { return nil }
                    let size = CGSize(width: 300, height: 450)
                    let scale = min(size.width / pageBounds.width, size.height / pageBounds.height)
                    let scaledSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
                    guard scaledSize.width > 0 && scaledSize.height > 0 && !scaledSize.width.isNaN && !scaledSize.height.isNaN else { return nil }
                    
                    let renderer = UIGraphicsImageRenderer(size: scaledSize)
                    return renderer.image { context in
                        UIColor.white.setFill()
                        context.fill(CGRect(origin: .zero, size: scaledSize))
                        
                        context.cgContext.translateBy(x: 0, y: scaledSize.height)
                        context.cgContext.scaleBy(x: scale, y: -scale)
                        
                        page.draw(with: .mediaBox, to: context.cgContext)
                    }
                }
                
                // Try up to the first 3 pages to find a portrait cover
                for i in 0..<min(document.pageCount, 3) {
                    if let page = document.page(at: i) {
                        let bounds = page.bounds(for: .mediaBox)
                        // Skip if it's the first page and appears to be a 2-page spread
                        if i == 0 && bounds.width > bounds.height && document.pageCount > 1 {
                            continue
                        }
                        return drawPage(page)
                    }
                }
                
                // Fallback to page 0 if no portrait pages were found
                if let page = document.page(at: 0) {
                    return drawPage(page)
                }
                return nil
            }
        }

        if ["cbz", "zip", "epub"].contains(ext) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            
            do {
                let archive = try Archive(url: url, accessMode: .read)

#if DEBUG
                // Check mimetype for EPUBs — debug only, runs on every cover load in production otherwise
                if ext == "epub" {
                    if let mimetypeEntry = archive["mimetype"] {
                        Logger.shared.log("[Flight Recorder] [0] mimetype Size: \(mimetypeEntry.uncompressedSize)", category: "Debug")
                        let compressionMethod = mimetypeEntry.type == .file ? (mimetypeEntry.compressedSize == mimetypeEntry.uncompressedSize ? "STORED (Likely)" : "DEFLATED") : "UNKNOWN"
                        Logger.shared.log("[Flight Recorder] [0] Compression: \(compressionMethod) (C: \(mimetypeEntry.compressedSize) / U: \(mimetypeEntry.uncompressedSize))", category: "Debug")
                        if mimetypeEntry.uncompressedSize == 20 {
                            Logger.shared.log("[Flight Recorder] ✅ Mimetype size is correct (20 bytes)", category: "Debug")
                        } else {
                            Logger.shared.log("[Flight Recorder] ❌ Mimetype size is WRONG: \(mimetypeEntry.uncompressedSize)", category: "Debug")
                        }
                        var data = Data()
                        _ = try? archive.extract(mimetypeEntry, consumer: { data.append($0) })
                        if let content = String(data: data, encoding: .ascii) {
                           Logger.shared.log("[Flight Recorder] 📄 Mimetype Content: '\(content)'", category: "Debug")
                           if content != "application/epub+zip" {
                               Logger.shared.log("[Flight Recorder] ❌ Mimetype Content INVALID", category: "Debug")
                           }
                        }
                    } else {
                        Logger.shared.log("[Flight Recorder] ❌ Mimetype file MISSING!", category: "Debug")
                    }
                }
#endif

                // ── Linear scan with early exit — no full sort needed to find the cover ──
                // The CBR path already uses prefix(5); we mirror that here. Sorting all
                // 400 entries of a CBZ just to read the first image was O(N log N) waste.
                let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
                var firstSpreadImage: UIImage? = nil
                var attempts = 0

                // Collect and sort only image entries (central directory read is fast;
                // we still need sorted order so page 1 is the cover, not a random entry).
                var imageEntries: [(String, ZIPFoundation.Entry)] = []
                for entry in archive {
                    if entry.type == .directory { continue }
                    let entryExt = (entry.path as NSString).pathExtension.lowercased()
                    guard imageExts.contains(entryExt),
                          !entry.path.contains("__MACOSX"),
                          !(entry.path as NSString).lastPathComponent.hasPrefix("._"),
                          !entry.path.hasSuffix(".DS_Store") else { continue }
                    imageEntries.append((entry.path, entry))
                    // Early collection cap: we only need the first few to find a portrait cover
                    if imageEntries.count >= 6 { break }
                }
                imageEntries.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }

                for (_, entry) in imageEntries {
                    // Safe cancellation check inside a synchronous nonisolated func:
                    // Task.isCancelled can only be called from async context; using
                    // withUnsafeCurrentTask avoids a Swift runtime crash.
                    var cancelled = false
                    withUnsafeCurrentTask { cancelled = $0?.isCancelled ?? false }
                    if cancelled { return nil }
                    
                    let image = autoreleasepool { () -> UIImage? in
                        var data = Data()
                        do {
                            _ = try archive.extract(entry) { data.append($0) }
                            return UIImage(data: data)
                        } catch {
                            Logger.shared.log("Failed to extract \(entry.path): \(error.localizedDescription)", category: "Archive", type: .error)
                            return nil
                        }
                    }
                    
                    if let img = image {
                        attempts += 1
                        if attempts == 1 && img.size.width > img.size.height {
                            firstSpreadImage = img
                            continue
                        }
                        return img
                    }
                }
                
                return firstSpreadImage
            } catch {
                Logger.shared.log("Failed to extract archive: \(error.localizedDescription)", category: "Archive", ty        // ── CBR / RAR Archives ─────────────────────────────────────────────────
        if ext == "cbr" || ext == "rar" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            return ConcurrencyLocks.unrarLock.withLock {
                do {
                    let archive = try Unrar.Archive(fileURL: url)
                    let entries = try archive.entries()

                    let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
                    let sorted = entries
                        .filter { entry in
                            guard !entry.directory,
                                   !entry.fileName.contains("__MACOSX"),
                                   !(entry.fileName as NSString).lastPathComponent.hasPrefix("._") && !(entry.fileName as NSString).lastPathComponent.hasSuffix(".DS_Store") else { return false }
                            return imageExts.contains((entry.fileName as NSString).pathExtension.lowercased())
                        }
                        .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

                    var firstSpread: UIImage? = nil
                    var attempts = 0
                    for entry in sorted.prefix(5) {
                        let image = autoreleasepool { () -> UIImage? in
                            do {
                                let data = try archive.extract(entry)
                                return UIImage(data: data)
                            } catch {
                                return nil
                            }
                        }
                        guard let img = image else { continue }
                        attempts += 1
                        // Skip landscape (two-page spread) on first attempt — prefer portrait cover
                        if attempts == 1 && img.size.width > img.size.height && sorted.count > 1 {
                            firstSpread = img
                            continue
                        }
                        return img
                    }
                    return firstSpread  // fallback if every page is landscape
                } catch {
                    Logger.shared.log("PhysicalFileSystemRouter: CBR cover extraction failed for '\(url.lastPathComponent)': \(error.localizedDescription)", category: "Archive", type: .error)
                    return nil
                }
            }
        }

        return nil
    }
    
    nonisolated static func getPageCountStatic(from url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            return ConcurrencyLocks.pdfLock.withLock {
                return PDFDocument(url: url)?.pageCount ?? 0
            }
        }

        if ["cbz", "zip", "epub"].contains(ext) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            
            do {
                let archive = try Archive(url: url, accessMode: .read)
                var count = 0
                for entry in archive {
                    if entry.type == .directory { continue }
                    let entryExt = (entry.path as NSString).pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "webp"].contains(entryExt) {
                        if entry.path.contains("__MACOSX") || entry.path.hasPrefix("._") || entry.path.hasSuffix(".DS_Store") { continue }
                        count += 1
                    }
                }
                return count
            } catch {
                Logger.shared.log("Failed to count pages in archive: \(error.localizedDescription)", category: "Archive", type: .error)
            }
            return 0
        }

        // ── CBR / RAR Archives ─────────────────────────────────────────────────
        if ext == "cbr" || ext == "rar" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
            return ConcurrencyLocks.unrarLock.withLock {
                do {
                    let archive = try Unrar.Archive(fileURL: url)
                    let entries = try archive.entries()
                    return entries.filter { entry in
                        guard !entry.directory,
                              !entry.fileName.contains("__MACOSX"),
                              !(entry.fileName as NSString).lastPathComponent.hasPrefix("._") && !(entry.fileName as NSString).lastPathComponent.hasSuffix(".DS_Store") else { return false }
                        return imageExts.contains((entry.fileName as NSString).pathExtension.lowercased())
                    }.count
                } catch {
                    Logger.shared.log("PhysicalFileSystemRouter: CBR page count failed for '\(url.lastPathComponent)': \(error.localizedDescription)", category: "Archive", type: .error)
                    return 0
                }
            }
        }

        return 0
    }
    
    nonisolated static func extractPageImage(from url: URL, pageIndex: Int) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            return ConcurrencyLocks.pdfLock.withLock {
                guard let document = PDFDocument(url: url) else { return nil }
                guard pageIndex >= 0 && pageIndex < document.pageCount else { return nil }
                guard let page = document.page(at: pageIndex) else { return nil }
                
                let pageBounds = page.bounds(for: .mediaBox)
                guard pageBounds.width > 0 && pageBounds.height > 0 && !pageBounds.width.isNaN && !pageBounds.height.isNaN else { return nil }
                let size = CGSize(width: 400, height: 560)
                let scale = min(size.width / pageBounds.width, size.height / pageBounds.height)
                let scaledSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
                guard scaledSize.width > 0 && scaledSize.height > 0 && !scaledSize.width.isNaN && !scaledSize.height.isNaN else { return nil }
                
                let renderer = UIGraphicsImageRenderer(size: scaledSize)
                return renderer.image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: scaledSize))
                    
                    context.cgContext.translateBy(x: 0, y: scaledSize.height)
                    context.cgContext.scaleBy(x: scale, y: -scale)
                    
                    page.draw(with: .mediaBox, to: context.cgContext)
                }
            }
        }

        if ["cbz", "zip", "epub"].contains(ext) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            
            do {
                let archive = try Archive(url: url, accessMode: .read)
                var imageEntries: [ZIPFoundation.Entry] = []
                for entry in archive {
                    if entry.type == .directory { continue }
                    let entryExt = (entry.path as NSString).pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "webp"].contains(entryExt) {
                        if entry.path.contains("__MACOSX") || entry.path.hasPrefix("._") || entry.path.hasSuffix(".DS_Store") { continue }
                        imageEntries.append(entry)
                    }
                }
                
                let sortedEntries = imageEntries.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
                
                guard pageIndex >= 0 && pageIndex < sortedEntries.count else { return nil }
                let targetEntry = sortedEntries[pageIndex]
                
                return autoreleasepool {
                    var data = Data()
                    do {
                        _ = try archive.extract(targetEntry) { chunk in
                            data.append(chunk)
                        }
                        return UIImage(data: data)
                    } catch {
                        return nil
                    }
                }
            } catch {
                Logger.shared.log("Failed to extract page image at index \(pageIndex) from archive: \(error.localizedDescription)", category: "Archive", type: .error)
            }
        }

        if ext == "cbr" || ext == "rar" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            return ConcurrencyLocks.unrarLock.withLock {
                do {
                    let archive = try Unrar.Archive(fileURL: url)
                    let entries = try archive.entries()

                    let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
                    let sorted = entries
                        .filter { entry in
                            guard !entry.directory,
                                   !entry.fileName.contains("__MACOSX"),
                                   !(entry.fileName as NSString).lastPathComponent.hasPrefix("._") && !(entry.fileName as NSString).lastPathComponent.hasSuffix(".DS_Store") else { return false }
                            return imageExts.contains((entry.fileName as NSString).pathExtension.lowercased())
                        }
                        .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

                    guard pageIndex >= 0 && pageIndex < sorted.count else { return nil }
                    let targetEntry = sorted[pageIndex]
                    return autoreleasepool {
                        do {
                            let data = try archive.extract(targetEntry)
                            return UIImage(data: data)
                        } catch {
                            return nil
                        }
                    }
                } catch {
                    Logger.shared.log("PhysicalFileSystemRouter: CBR page image extraction failed for index \(pageIndex): \(error.localizedDescription)", category: "Archive", type: .error)
                    return nil
                }
            }
        }
        return nil
    }

    
    // ✅ NEW: Extract Smart Panels from ComicInfo.xml
}

