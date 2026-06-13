import Foundation
import UIKit
import SwiftUI
import PDFKit
import ZIPFoundation
import Unrar

private let _globalCoversDirectory: URL = {
    let fileManager = FileManager.default
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
    let dir = appSupportDir.appendingPathComponent("Covers", isDirectory: true)
    if !fileManager.fileExists(atPath: dir.path) {
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
}()

/// Safely handles all iOS Storage interactions, including disk persistence, thumbnail caching into Application Support, and atomic NSFileCoordinator bindings independent from the Presentation logic.
@MainActor
class PhysicalFileSystemRouter {
    static let shared = PhysicalFileSystemRouter()
    private init() {}
    
    // MARK: - Core File IO Storage

    nonisolated static func getCoversDirectory() -> URL {
        return _globalCoversDirectory
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
                        kCGImageSourceThumbnailMaxPixelSize: 600   // grid cells never exceed ~200pt (Retina 3x = 600px)
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
        
        let key = pdf.id.uuidString as NSString
        var thumbnailCost: Int? = nil
        var finalThumbnail: UIImage? = nil
        
        autoreleasepool {
            if let image = UIImage(data: data) {
                let thumbnail = image.preparingThumbnail(of: CGSize(width: 300, height: 450)) ?? image
                finalThumbnail = thumbnail
                // Pixel byte count approximation — accurate enough for NSCache pressure, zero CPU overhead.
                thumbnailCost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
            }
        }
        
        Task { @MainActor in
            if let thumb = finalThumbnail, let cost = thumbnailCost {
                manager.thumbnailCache.setObject(thumb, forKey: key, cost: cost)
            }
            if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[index].coverImageData = nil
                // Route through the debounced subject so rapid backfill saves coalesce
                // into one SwiftUI diff per 150ms window instead of one per cover write.
                manager.thumbnailReadySubject.send()
            }
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
            guard let variantID = pdf.metadata.selectedCoverID,
                  let variantURL = pdf.metadata.coverVariants[variantID],
                  FileManager.default.fileExists(atPath: variantURL.path) else { return nil }
            let optData = try? Data(contentsOf: variantURL)
            if let data = optData, let image = UIImage(data: data) {
                return image.jpegData(compressionQuality: 0.85)
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
            image?.jpegData(compressionQuality: 0.85)
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
            image?.jpegData(compressionQuality: 0.85)
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
            guard let image, let jpegData = image.jpegData(compressionQuality: 0.85) else { return }
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
                
                // ✅ FIX: Safely check the cache on the MainActor
                let isCached = await MainActor.run { manager.thumbnailCache.object(forKey: key) != nil }
                guard !isCached else { continue }
                
                guard let coverURL = getCoverURL(for: pdf),
                      FileManager.default.fileExists(atPath: coverURL.path) else { continue }

                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let src = CGImageSourceCreateWithURL(coverURL as CFURL, srcOpts) else { return nil }
                    let downsampleOpts = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600   // grid cells never exceed ~200pt (Retina 3x = 600px)
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
        // ✅ OOM Crash Fix: Hand off all missing covers to the `ThumbnailGenerationQueue`.
        // This ensures they are processed strictly maxConcurrent = 2 at a time, preventing
        // overlapping bulk tasks from exhausting device RAM during large imports.
        let pdfsNeedingCovers = allPDFs.filter { pdf in
            guard let coverURL = getCoverURL(for: pdf) else { return true }
            return !FileManager.default.fileExists(atPath: coverURL.path)
        }
        guard !pdfsNeedingCovers.isEmpty else { return }
        Task(priority: .background) {
            for pdf in pdfsNeedingCovers {
                await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: manager)
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
        let key = pdf.id.uuidString as NSString
        let isCached = await MainActor.run { manager.thumbnailCache.object(forKey: key) != nil }
        if isCached { return }
        
        var generatedImage: UIImage? = nil
        if let coverURL = self.getCoverURL(for: pdf) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) {
                let downsampleOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720
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
            await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: manager)
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
                        kCGImageSourceThumbnailMaxPixelSize: 720
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
                await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: manager)
            }
        }
        return nil
    }
    
    // MARK: - Native Thread-Safe Physical OS Interactions
    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String, manager: ConversionManager, saveAfter: Bool = true) async throws {
        guard let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) else {
            throw NSError(domain: "Database", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found within internal database loop."])
        }
        
        // Close any active handles/locks on this file before attempting rename
        await ArchiveManager.shared.clearCache()
        
        let fileManager = FileManager.default
        var currentURL = pdf.url
        
        // Acquire security-scoped resource access if linked external file
        var needsStopAccess = false
        if case .linked(let bm) = pdf.sourceMode {
            if let resolved = try? BookmarkResolver.shared.resolve(bm) {
                needsStopAccess = resolved.startAccessingSecurityScopedResource()
                currentURL = resolved
            }
        }
        
        defer {
            if needsStopAccess {
                currentURL.stopAccessingSecurityScopedResource()
            }
        }
        
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw NSError(domain: "FileSystem", code: 404, userInfo: [NSLocalizedDescriptionKey: "The physical file no longer exists at path: \(currentURL.path)"])
        }
        
        let pathExtension = currentURL.pathExtension
        let cleanName = newName.replacingOccurrences(of: "/", with: "-")
                               .replacingOccurrences(of: "\\", with: "-")
                               .replacingOccurrences(of: ":", with: "-")
                               .replacingOccurrences(of: "*", with: "")
                               .replacingOccurrences(of: "?", with: "")
                               .replacingOccurrences(of: "\"", with: "'")
                               .replacingOccurrences(of: "<", with: "(")
                               .replacingOccurrences(of: ">", with: ")")
                               .replacingOccurrences(of: "|", with: "-")
        
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
            Logger.shared.log("Move Failure from \(currentURL.path) to \(newURL.path): \(error)", category: "FileSystem", type: .error)
            throw error
        }
        
        // Regenerate bookmark for new URL if it's a linked file
        if case .linked = pdf.sourceMode {
            let accessingNew = newURL.startAccessingSecurityScopedResource()
            do {
                let newBookmark = try newURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                manager.convertedPDFs[idx].sourceMode = .linked(bookmarkData: newBookmark)
            } catch {
                Logger.shared.log("Failed to create new bookmark after rename: \(error.localizedDescription)", category: "FileSystem", type: .error)
            }
            if accessingNew {
                newURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Update database record in-memory
        manager.convertedPDFs[idx].url = newURL
        manager.convertedPDFs[idx].name = newURL.lastPathComponent
        
        if saveAfter {
            manager.saveLibrary()
        }
        
        // Broadcast file rename to active reader sessions
        NotificationCenter.default.post(
            name: Notification.Name("InksyncPro.fileDidRename"),
            object: nil,
            userInfo: ["pdfID": pdf.id, "newURL": newURL]
        )
    }

    func safelyRenameSeries(issues: [ConvertedPDF], newSeriesName: String, manager: ConversionManager) async throws {
        let cleanSeriesName = newSeriesName.trimmingCharacters(in: .whitespacesAndNewlines)
                                           .replacingOccurrences(of: "/", with: "-")
                                           .replacingOccurrences(of: "\\", with: "-")
                                           .replacingOccurrences(of: ":", with: "-")
                                           .replacingOccurrences(of: "*", with: "")
                                           .replacingOccurrences(of: "?", with: "")
                                           .replacingOccurrences(of: "\"", with: "'")
                                           .replacingOccurrences(of: "<", with: "(")
                                           .replacingOccurrences(of: ">", with: ")")
                                           .replacingOccurrences(of: "|", with: "-")
        
        guard !cleanSeriesName.isEmpty else { return }

        // Find database indices of all issues in the target group
        var dbIndices: [Int] = []
        for issue in issues {
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == issue.id }) {
                dbIndices.append(idx)
            }
        }
        
        guard !dbIndices.isEmpty else { return }
        
        let fileManager = FileManager.default
        let pdfURLs = dbIndices.map { manager.convertedPDFs[$0].url }
        let parentURLs = pdfURLs.map { $0.deletingLastPathComponent() }
        let uniqueParents = Set(parentURLs)
        
        var folderRenamed = false
        var oldFolderURL: URL? = nil
        var newFolderURL: URL? = nil
        
        // 1. If all files share a common parent subfolder, attempt directory rename first
        if uniqueParents.count == 1, let commonParent = uniqueParents.first {
            let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let inboxDir = appSupport?.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            
            let isRoot = commonParent.path == docDir?.path ||
                         commonParent.path == inboxDir?.path ||
                         commonParent.path == tmpDir.path ||
                         commonParent.path == docDir?.deletingLastPathComponent().path
            
            if !isRoot {
                oldFolderURL = commonParent
                let containerDir = commonParent.deletingLastPathComponent()
                var targetFolderURL = containerDir.appendingPathComponent(cleanSeriesName, isDirectory: true)
                
                // Keep target folder unique
                var counter = 2
                while fileManager.fileExists(atPath: targetFolderURL.path) {
                    targetFolderURL = containerDir.appendingPathComponent("\(cleanSeriesName)_v\(counter)", isDirectory: true)
                    counter += 1
                }
                
                newFolderURL = targetFolderURL
                
                // Clear cached open handles before renaming directory
                await ArchiveManager.shared.clearCache()
                await PDFRenderActor.shared.clear()
                
                var folderNeedsStopAccess = false
                let firstPDF = manager.convertedPDFs[dbIndices[0]]
                
                // Start access for security scoped parent if linked
                if case .linked(let bm) = firstPDF.sourceMode {
                    if let resolvedFile = try? BookmarkResolver.shared.resolve(bm) {
                        folderNeedsStopAccess = resolvedFile.startAccessingSecurityScopedResource()
                    }
                }
                
                do {
                    try fileManager.moveItem(at: commonParent, to: targetFolderURL)
                    folderRenamed = true
                    Logger.shared.log("Folder Renamed successfully: \(commonParent.lastPathComponent) -> \(targetFolderURL.lastPathComponent)", category: "FileSystem", type: .success)
                } catch {
                    Logger.shared.log("Folder Rename Failed: \(error.localizedDescription). Will fallback to renaming files inside old folder.", category: "FileSystem", type: .warning)
                }
                
                if folderNeedsStopAccess {
                    if let resolvedFile = try? BookmarkResolver.shared.resolve(firstPDF.driveBookmarkData ?? Data()) {
                        resolvedFile.stopAccessingSecurityScopedResource()
                    }
                }
            }
        }
        
        // 2. Update URLs of all library items matching the old parent path prefix (cascading rename)
        if folderRenamed, let oldFolder = oldFolderURL, let newFolder = newFolderURL {
            for i in 0..<manager.convertedPDFs.count {
                let pdfURL = manager.convertedPDFs[i].url
                if pdfURL.path.hasPrefix(oldFolder.path) {
                    let relativePath = String(pdfURL.path.dropFirst(oldFolder.path.count))
                    let resolvedNewURL = newFolder.appendingPathComponent(relativePath)
                    
                    manager.convertedPDFs[i].url = resolvedNewURL
                    manager.convertedPDFs[i].metadata.series = cleanSeriesName
                    
                    // Re-register bookmark if linked
                    if case .linked = manager.convertedPDFs[i].sourceMode {
                        let accessing = resolvedNewURL.startAccessingSecurityScopedResource()
                        if let newBM = try? resolvedNewURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                            manager.convertedPDFs[i].sourceMode = .linked(bookmarkData: newBM)
                        }
                        if accessing { resolvedNewURL.stopAccessingSecurityScopedResource() }
                    }
                }
            }
        }
        
        // 3. Rename individual files within the parent folder
        for idx in dbIndices {
            manager.convertedPDFs[idx].metadata.series = cleanSeriesName
            let pdf = manager.convertedPDFs[idx]
            let newFilename = manager.generateRenameFilename(pdf: pdf, newSeriesName: cleanSeriesName)
            
            do {
                try await safelyRenamePhysicalFile(pdf: pdf, newName: newFilename, manager: manager, saveAfter: false)
            } catch {
                Logger.shared.log("File rename failed for \(pdf.name): \(error.localizedDescription). Falling back to logical rename.", category: "FileSystem", type: .warning)
                // Fallback logical rename: update database name & extension only
                let ext = pdf.url.pathExtension
                let finalName = newFilename.isEmpty ? pdf.name : "\(newFilename).\(ext)"
                manager.convertedPDFs[idx].name = finalName
            }
        }
        
        manager.saveLibrary()
    }
    
    // MARK: - Extracted Static Disk Helpers
    nonisolated static func excludeFromBackup(at url: URL) {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            Logger.shared.log("Failed to exclude from backup at \(url.lastPathComponent): \(error.localizedDescription)", category: "FileSystem", type: .error)
        }
    }
    
    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing: Bool
            if url.path.contains("Documents") || url.path.contains("tmp") {
                accessing = false
            } else {
                accessing = url.startAccessingSecurityScopedResource()
            }
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
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
            
            // Try up to the first 5 pages to find a portrait cover
            var firstSpreadImage: UIImage? = nil
            for i in 0..<min(document.pageCount, 5) {
                if let page = document.page(at: i) {
                    let bounds = page.bounds(for: .mediaBox)
                    // Skip landscape (two-page spread)
                    if bounds.width > bounds.height && document.pageCount > 1 {
                        if firstSpreadImage == nil { firstSpreadImage = drawPage(page) }
                        continue
                    }
                    if let portrait = drawPage(page) { return portrait }
                }
            }
            
            // Fallback to the first spread, or page 0 if nothing else worked
            if let fallback = firstSpreadImage { return fallback }
            if let page = document.page(at: 0) {
                return drawPage(page)
            }
            return nil
        }

        if ["cbz", "zip", "epub"].contains(ext) {
            let accessing: Bool
            if url.path.contains("Documents") || url.path.contains("tmp") {
                accessing = false
            } else {
                accessing = url.startAccessingSecurityScopedResource()
            }
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
                // Collect and sort ALL image entries first to ensure we get the true first pages
                var imageEntries: [(String, ZIPFoundation.Entry)] = []
                for entry in archive {
                    if entry.type == .directory { continue }
                    let entryExt = (entry.path as NSString).pathExtension.lowercased()
                    guard imageExts.contains(entryExt),
                          !entry.path.contains("__MACOSX"),
                          !(entry.path as NSString).lastPathComponent.hasPrefix("._"),
                          !entry.path.hasSuffix(".DS_Store") else { continue }
                    imageEntries.append((entry.path, entry))
                }
                imageEntries.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }

                var firstSpreadImage: UIImage? = nil
                for (_, entry) in imageEntries.prefix(6) {
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
                            
                            let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                            guard let source = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
                            
                            let downsampleOpts = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 600
                            ] as CFDictionary
                            
                            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts) {
                                return UIImage(cgImage: cg)
                            }
                            return nil
                        } catch {
                            Logger.shared.log("Failed to extract \(entry.path): \(error.localizedDescription)", category: "Archive", type: .error)
                            return nil
                        }
                    }
                    
                    if let img = image {
                        if img.size.width > img.size.height {
                            if firstSpreadImage == nil { firstSpreadImage = img }
                            continue
                        }
                        return img
                    }
                }
                
                return firstSpreadImage
            } catch {
                Logger.shared.log("Failed to extract archive: \(error.localizedDescription)", category: "Archive", type: .error)
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

                    var firstSpread: UIImage? = nil
                    for entry in sorted.prefix(6) {
                        let image = autoreleasepool { () -> UIImage? in
                            do {
                                let data = try archive.extract(entry)
                                
                                let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                                guard let source = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
                                
                                let downsampleOpts = [
                                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceShouldCacheImmediately: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 600
                                ] as CFDictionary
                                
                                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts) {
                                    return UIImage(cgImage: cg)
                                }
                                return nil
                            } catch {
                                return nil
                            }
                        }
                        guard let img = image else { continue }
                        if img.size.width > img.size.height {
                            if firstSpread == nil { firstSpread = img }
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

        if ext == "cbt" || ext == "tar" {
            return CBTExtractor.extractFirstImage(from: url)
        }

        return nil
    }
    
    nonisolated static func getPageCountStatic(from url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            return PDFDocument(url: url)?.pageCount ?? 0
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

        if ext == "cbt" || ext == "tar" {
            return CBTExtractor.getPageCount(from: url)
        }

        return 0
    }
    
    nonisolated static func extractPageImage(from url: URL, pageIndex: Int) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
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
                        // ✅ Memory Optimization: Downsample directly from data without loading full bitmap
                        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                        guard let source = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
                        let downsampleOpts = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 600
                        ] as CFDictionary
                        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts) else { return nil }
                        return UIImage(cgImage: cgImage)
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
                            // ✅ Memory Optimization: Downsample directly from data without loading full bitmap
                            let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
                            guard let source = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
                            let downsampleOpts = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 600
                            ] as CFDictionary
                            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts) else { return nil }
                            return UIImage(cgImage: cgImage)
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

/// A lightweight queue to strictly limit concurrent thumbnail generation.
/// This prevents OOM (Out of Memory) crashes when the UI requests 30+ missing covers at once.
actor ThumbnailGenerationQueue {
    static let shared = ThumbnailGenerationQueue()
    
    // We cannot easily hold `ConversionManager` in an actor array without warnings, 
    // but since it's an ObservableObject (reference type), it's safe to pass.
    private var pending: [(ConvertedPDF, ConversionManager)] = []
    private var inFlight: Set<UUID> = []
    private var activeCount = 0
    private let maxConcurrent = 2
    
    func enqueue(_ pdf: ConvertedPDF, manager: ConversionManager) {
        // Prevent duplicate queuing for the same file
        guard !inFlight.contains(pdf.id) else { return }
        if pending.contains(where: { $0.0.id == pdf.id }) { return }
        
        pending.append((pdf, manager))
        dequeue()
    }
    
    private func dequeue() {
        guard activeCount < maxConcurrent, !pending.isEmpty else { return }
        let (pdf, manager) = pending.removeFirst()
        
        activeCount += 1
        inFlight.insert(pdf.id)
        
        Task.detached(priority: .background) {
            await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: manager)
            await ThumbnailGenerationQueue.shared.taskDidFinish(id: pdf.id)
        }
    }
    
    func taskDidFinish(id: UUID) {
        activeCount -= 1
        inFlight.remove(id)
        dequeue()
    }
    
    func generateThumbnail(for pdf: ConvertedPDF, in manager: ConversionManager) async -> UIImage? {
        await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: manager)
        let key = pdf.id.uuidString as NSString
        return await MainActor.run { manager.thumbnailCache.object(forKey: key) }
    }
}

