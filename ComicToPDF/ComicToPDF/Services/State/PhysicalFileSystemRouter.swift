import Foundation
import UIKit
import SwiftUI
import SwiftData
import PDFKit
import ZIPFoundation
import Unrar
import Vision

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
    
    private var backfillTask: Task<Void, Never>?
    
    // MARK: - Core File IO Storage

    nonisolated static func getCoversDirectory() -> URL {
        return _globalCoversDirectory
    }

    // MARK: - Directory Reaper (Automatic Empty Folder Deletion)

    nonisolated private static let protectedDirectoryNames: Set<String> = [
        "documents", "inbox", "tmp", "caches", "application support",
        "file provider storage", "downloads", "inksyncstaging_", "folder_spider_",
        "folderspider_", "inksyncvault", "libraryvault", "recovered_vault",
        "covers", "backups", "snapshots"
    ]

    /// Safely reaps an array of candidate directory URLs if they are subdirectories inside Documents
    /// and contain zero readable files/subdirectories.
    nonisolated static func reapEmptyDirectories(at candidateURLs: [URL]) {
        let fm = FileManager.default
        guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() else { return }

        for dir in candidateURLs {
            let canonicalDir = dir.resolvingSymlinksInPath()
            
            // Invariant 1: Must be strictly located inside Documents directory, but NOT Documents itself
            guard canonicalDir.path.hasPrefix(docDir.path), canonicalDir.path != docDir.path else { continue }
            
            // Invariant 2: Folder name must not match protected system/vault roots
            let folderName = canonicalDir.lastPathComponent.lowercased()
            guard !protectedDirectoryNames.contains(folderName) else { continue }
            
            // Invariant 3: Check contents (excluding hidden files like .DS_Store)
            do {
                let items = try fm.contentsOfDirectory(at: canonicalDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                if items.isEmpty {
                    // Also purge any hidden leftover files (.DS_Store) before removing directory
                    let allItems = (try? fm.contentsOfDirectory(at: canonicalDir, includingPropertiesForKeys: nil)) ?? []
                    for hidden in allItems {
                        try? fm.removeItem(at: hidden)
                    }
                    try fm.removeItem(at: canonicalDir)
                    Logger.shared.log("Directory Reaper: Automatically deleted empty folder '\(dir.lastPathComponent)'", category: "FileSystem", type: .info)
                }
            } catch {
                // Directory may already be deleted or not accessible
            }
        }
    }

    /// Recursively sweeps the Documents directory and reaps any empty series or staging folders.
    nonisolated static func reapAllEmptySeriesDirectoriesInDocuments() {
        let fm = FileManager.default
        guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() else { return }

        guard let subdirs = try? fm.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }

        var candidateDirs: [URL] = []
        for url in subdirs {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                candidateDirs.append(url)
            }
        }

        reapEmptyDirectories(at: candidateDirs)
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

    func purgeLegacyCachedCoversIfNeeded(manager: ConversionManager) {
        guard !UserDefaults.standard.bool(forKey: "didPurgeDisclaimerAndBlankCovers_v4") else { return }
        UserDefaults.standard.set(true, forKey: "didPurgeDisclaimerAndBlankCovers_v4")
        
        Task.detached(priority: .utility) {
            let coversDir = Self.getCoversDirectory()
            let fm = FileManager.default
            var purgedCount = 0
            if let files = try? fm.contentsOfDirectory(at: coversDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "jpg" {
                    if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
                        if Self.containsDisclaimerText(in: img) || Self.isBlankOrSolidColorImage(img) || Self.isSuspiciouslyLowRes(img) {
                            try? fm.removeItem(at: file)
                            purgedCount += 1
                        }
                    }
                }
            }
            // Also purge bad entries from ThumbnailDaemon cache directory
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            let daemonCacheDir = appSupport.appendingPathComponent("ThumbnailCache", isDirectory: true)
            if let daemonFiles = try? fm.contentsOfDirectory(at: daemonCacheDir, includingPropertiesForKeys: nil) {
                for file in daemonFiles where file.pathExtension.lowercased() == "webp" {
                    if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
                        if Self.containsDisclaimerText(in: img) || Self.isBlankOrSolidColorImage(img) || Self.isSuspiciouslyLowRes(img) {
                            try? fm.removeItem(at: file)
                            purgedCount += 1
                        }
                    }
                }
            }
            
            await MainActor.run {
                manager.thumbnailCache.removeAllObjects()
                if purgedCount > 0 {
                    Logger.shared.log("PhysicalFileSystemRouter: Purged \(purgedCount) disclaimer/blank covers from disk. Triggering backfill.", category: "Library")
                    Self.shared.backfillMissingThumbnails(manager: manager)
                }
            }
        }
    }
    
    func migrateFlatFilesToSeriesDirectories(manager: ConversionManager) async {
        let fileManager = FileManager.default
        guard let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        var updated = false
        var indicesToRemove = Set<Int>()
        
        for i in 0..<manager.convertedPDFs.count {
            let pdf = manager.convertedPDFs[i]
            let fileURL = pdf.url
            
            // Only migrate local files that are flat in the Documents directory
            guard case .local = pdf.sourceMode else { continue }
            
            let parentDir = fileURL.deletingLastPathComponent()
            if parentDir.path == docDir.path {
                // Find or infer the Series name using same fallback logic as database/UI grouping
                let rawSeries = (pdf.metadata.series?.isEmpty == false) ? pdf.metadata.series! : MetadataHeuristics.cleanFilename(pdf.name)
                let series = SeriesNameParser.cleanFolderName(rawSeries).trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !series.isEmpty else { continue }
                
                let cleanSeries = series.replacingOccurrences(of: "/", with: "-")
                                       .replacingOccurrences(of: "\\", with: "-")
                                       .replacingOccurrences(of: ":", with: "-")
                                       .replacingOccurrences(of: "*", with: "")
                                       .replacingOccurrences(of: "?", with: "")
                                       .replacingOccurrences(of: "\"", with: "'")
                                       .replacingOccurrences(of: "<", with: "(")
                                       .replacingOccurrences(of: ">", with: ")")
                                       .replacingOccurrences(of: "|", with: "-")
                
                guard !cleanSeries.isEmpty else { continue }
                
                let targetDir = docDir.appendingPathComponent(cleanSeries, isDirectory: true)
                let destURL = targetDir.appendingPathComponent(fileURL.lastPathComponent)
                
                // Ensure source file actually exists on disk before attempting migration
                guard fileManager.fileExists(atPath: fileURL.path) else { continue }

                do {
                    // Create target directory if needed
                    try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    
                    var resolvedDestURL = destURL
                    var isRedundantDuplicate = false
                    if fileManager.fileExists(atPath: destURL.path) {
                        let srcSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                        let dstSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                        
                        if srcSize == dstSize || (dstSize > 0 && srcSize == 0) {
                            // Identical file already exists at destination — remove redundant flat file
                            try? fileManager.removeItem(at: fileURL)
                            resolvedDestURL = destURL
                            isRedundantDuplicate = true
                            Logger.shared.log("Pruned redundant flat duplicate \(fileURL.lastPathComponent); using existing series copy.", category: "FileSystem", type: .info)
                        } else {
                            // Genuinely different file with same name — resolve unique suffix
                            let nameWithoutExt = destURL.deletingPathExtension().lastPathComponent
                            let ext = destURL.pathExtension
                            var counter = 1
                            var checkURL = targetDir.appendingPathComponent("\(nameWithoutExt) (\(counter)).\(ext)")
                            while fileManager.fileExists(atPath: checkURL.path) {
                                counter += 1
                                checkURL = targetDir.appendingPathComponent("\(nameWithoutExt) (\(counter)).\(ext)")
                            }
                            resolvedDestURL = checkURL
                            try fileManager.moveItem(at: fileURL, to: resolvedDestURL)
                        }
                    } else {
                        // Move the file on disk
                        try fileManager.moveItem(at: fileURL, to: resolvedDestURL)
                    }
                    
                    PhysicalFileSystemRouter.excludeFromBackup(at: resolvedDestURL)
                    
                    let canonicalDest = resolvedDestURL.fastCanonicalPath
                    let alreadyTracked = manager.convertedPDFs.indices.contains { otherIdx in
                        otherIdx != i && manager.convertedPDFs[otherIdx].url.fastCanonicalPath == canonicalDest
                    }
                    
                    if isRedundantDuplicate || alreadyTracked {
                        // Destination already tracked in memory: delete duplicate flat record so two records don't point to same file
                        indicesToRemove.insert(i)
                        updated = true
                    } else {
                        // Update the model url
                        manager.convertedPDFs[i].url = resolvedDestURL
                        
                        // Keep the model's logical series metadata in perfect sync with the grouping
                        if manager.convertedPDFs[i].metadata.series != series {
                            manager.convertedPDFs[i].metadata.series = series
                        }
                        
                        updated = true
                        Logger.shared.log("Migrated flat file \(fileURL.lastPathComponent) to series directory \(cleanSeries)", category: "FileSystem", type: .success)
                    }
                } catch {
                    Logger.shared.log("Failed to migrate flat file \(fileURL.lastPathComponent) to series directory: \(error.localizedDescription)", category: "FileSystem", type: .error)
                }
            }
        }
        
        if !indicesToRemove.isEmpty {
            for idx in indicesToRemove.sorted(by: >) {
                if idx < manager.convertedPDFs.count {
                    manager.convertedPDFs.remove(at: idx)
                }
            }
        }
        
        if updated {
            manager.saveLibrary()
        }
    }
    
    func loadCoverThumbnail(for pdf: ConvertedPDF, manager: ConversionManager) async -> UIImage? {
        let keyStr = pdf.id.uuidString
        if let cached = manager.thumbnailCache.object(forKey: keyStr as NSString) {
            if Self.containsDisclaimerText(in: cached) || Self.isBlankOrSolidColorImage(cached) || Self.isSuspiciouslyLowRes(cached) {
                manager.thumbnailCache.removeObject(forKey: keyStr as NSString)
                if let url = getCoverURL(for: pdf) { try? FileManager.default.removeItem(at: url) }
                Task { await ThumbnailDaemon.shared.clearCache(for: pdf.id) }
                Task(priority: .userInitiated) {
                    await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: manager)
                }
                return nil
            }
            return cached
        }
        // ✅ PERF: Resolve cover URL on MainActor *once*, before the background task.
        // Avoids an implicit actor-hop back to MainActor per cell during scroll.
        let coverURL = getCoverURL(for: pdf)
        let coverImageData = pdf.coverImageData
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // 1. Check ultra-fast Daemon cache first
            if let daemonCached = await ThumbnailDaemon.shared.getCachedThumbnail(for: pdf.id) {
                if Self.containsDisclaimerText(in: daemonCached) || Self.isBlankOrSolidColorImage(daemonCached) || Self.isSuspiciouslyLowRes(daemonCached) {
                    await ThumbnailDaemon.shared.clearCache(for: pdf.id)
                    if let url = coverURL { try? FileManager.default.removeItem(at: url) }
                    await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: manager)
                    return nil
                }
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
                        if Self.containsDisclaimerText(in: thumbnail) || Self.isBlankOrSolidColorImage(thumbnail) || Self.isSuspiciouslyLowRes(thumbnail) {
                            try? FileManager.default.removeItem(at: url)
                            await ThumbnailDaemon.shared.clearCache(for: pdf.id)
                            await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: manager)
                            return nil
                        }
                        await MainActor.run { manager.thumbnailCache.setObject(thumbnail, forKey: keyStr as NSString) }
                        return thumbnail
                    }
                }
            }
            
            if let data = coverImageData, let image = UIImage(data: data) {
                if !Self.containsDisclaimerText(in: image) && !Self.isBlankOrSolidColorImage(image) && !Self.isSuspiciouslyLowRes(image) {
                    return image
                }
            }
            return nil
        }.value
    }
    
    func saveCoverImage(_ data: Data, for pdf: ConvertedPDF, manager: ConversionManager) {
        guard let coverURL = getCoverURL(for: pdf) else { return }
        let pdfID = pdf.id
        
        // Clear ThumbnailDaemon cache (both memory and disk) so the updated cover is generated
        Task {
            await ThumbnailDaemon.shared.clearCache(for: pdfID)
        }
        
        Task.detached(priority: .background) {
            try? data.write(to: coverURL)
            
            let key = pdfID.uuidString as NSString
            var thumbnailCost: Int? = nil
            var finalThumbnail: UIImage? = nil
            
            autoreleasepool {
                if let image = UIImage(data: data) {
                    let thumbnail = image.preparingThumbnail(of: CGSize(width: 300, height: 450)) ?? image
                    finalThumbnail = thumbnail
                    thumbnailCost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
                }
            }
            
            await MainActor.run {
                if let thumb = finalThumbnail, let cost = thumbnailCost {
                    manager.thumbnailCache.setObject(thumb, forKey: key, cost: cost)
                }
                if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdfID }) {
                    if manager.convertedPDFs[index].coverImageData != nil {
                        manager.convertedPDFs[index].coverImageData = nil
                    }
                    // Route through the debounced subject so rapid backfill saves coalesce
                    // into one SwiftUI diff per 150ms window instead of one per cover write.
                    manager.thumbnailReadySubject.send(pdfID)
                }
            }
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF, manager: ConversionManager) {
        deletePDFs([pdf], manager: manager)
    }

    func deletePDFs(_ pdfs: [ConvertedPDF], manager: ConversionManager) {
        guard !pdfs.isEmpty else { return }
        let idsToDelete = Set(pdfs.map { $0.id })
        
        // 1. Remove from UI state atomically in a single pass for zero-latency UI update
        manager.convertedPDFs.removeAll { idsToDelete.contains($0.id) }
        LibraryService.shared.items.removeAll { idsToDelete.contains($0.id) }
        manager.pruneEmptyCollections()
        manager.saveLibrary()
        
        let context = InksyncProApp.sharedModelContainer.mainContext
        if let allDocs = try? context.fetch(FetchDescriptor<SDConvertedPDF>()) {
            for doc in allDocs where idsToDelete.contains(doc.id) {
                context.delete(doc)
            }
            try? context.save()
        }
        let metadataMap: [UUID: (name: String, author: String?)] = Dictionary(
            uniqueKeysWithValues: pdfs.map { ($0.id, ($0.name, $0.metadata.author)) }
        )
        
        let descriptor = FetchDescriptor<SDAnnotation>()
        if let allAnnotations = try? context.fetch(descriptor) {
            var modified = false
            for ann in allAnnotations {
                if let meta = metadataMap[ann.pdfID] {
                    if ann.readwiseBookTitle == nil || ann.readwiseBookTitle?.isEmpty == true {
                        ann.readwiseBookTitle = meta.name
                        modified = true
                    }
                    if ann.readwiseAuthor == nil || ann.readwiseAuthor?.isEmpty == true {
                        ann.readwiseAuthor = meta.author
                        modified = true
                    }
                }
            }
            if modified {
                try? context.save()
                DatabaseBackupService.shared.scheduleCompaction()
            }
        }
        
        // 2. Offload heavy file destruction of all targets & covers to background thread
        let targets: [(fileURL: URL, coverURL: URL?, name: String)] = pdfs.map { pdf in
            (fileURL: pdf.url, coverURL: getCoverURL(for: pdf), name: pdf.name)
        }
        
        Task.detached(priority: .background) {
            let fm = FileManager.default
            var deletedCount = 0
            var parentDirsToCheck = Set<URL>()
            for item in targets {
                if fm.fileExists(atPath: item.fileURL.path) {
                    let parent = item.fileURL.deletingLastPathComponent()
                    try? fm.removeItem(at: item.fileURL)
                    deletedCount += 1
                    parentDirsToCheck.insert(parent)
                }
                if let coverURL = item.coverURL, fm.fileExists(atPath: coverURL.path) {
                    try? fm.removeItem(at: coverURL)
                }
            }
            Logger.shared.log("Batch deleted \(deletedCount) files & covers in background", category: "Library", type: .info)

            // Enterprise Directory Reaper: Delete any series directory that is now completely empty
            Self.reapEmptyDirectories(at: Array(parentDirsToCheck))
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
        
        if let coverURL = getCoverURL(for: pdf), FileManager.default.fileExists(atPath: coverURL.path) {
            if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                if !Self.containsDisclaimerText(in: img) && !Self.isBlankOrSolidColorImage(img) && !Self.isSuspiciouslyLowRes(img) {
                    return
                }
            }
            try? FileManager.default.removeItem(at: coverURL)
        }
        
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
        
        let isEPUB = url.pathExtension.lowercased() == "epub"
        let image: UIImage?
        if isEPUB {
            image = await extractEPUBReadCover(from: url)
        } else {
            image = await Task.detached(priority: .background) { () -> UIImage? in
                return PhysicalFileSystemRouter.extractCoverImageStatic(from: url)
            }.value
        }
        
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
        // Skip if cover already exists on disk and is valid
        if let coverURL = getCoverURL(for: pdf), FileManager.default.fileExists(atPath: coverURL.path) {
            if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                if !Self.containsDisclaimerText(in: img) && !Self.isBlankOrSolidColorImage(img) && !Self.isSuspiciouslyLowRes(img) {
                    return
                }
            }
            try? FileManager.default.removeItem(at: coverURL)
        }
        
        let isEPUB = pdf.url.pathExtension.lowercased() == "epub" || localURL.pathExtension.lowercased() == "epub"
        let image: UIImage?
        if isEPUB {
            image = await extractEPUBReadCover(from: localURL)
        } else {
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                PhysicalFileSystemRouter.extractCoverImageStatic(from: localURL)
            }.value
        }
        
        let jpegData = autoreleasepool {
            image?.jpegData(compressionQuality: 0.85)
        }
        guard let data = jpegData else { return }
        saveCoverImage(data, for: pdf, manager: manager)
        Logger.shared.log("PhysicalFileSystemRouter: Cloud cover generated for '\(pdf.name)'", category: "Cloud", type: .success)
    }

    private func extractEPUBReadCover(from url: URL) async -> UIImage? {
        let metadata = await EBookParser.shared.parse(epub: url)
        let title = (metadata?.title.isEmpty == false) ? metadata!.title : url.deletingPathExtension().lastPathComponent
        let author = metadata?.author ?? ""
        
        // 1. Try explicit coverItem from OPF
        if let coverItem = metadata?.coverItem, !coverItem.isEmpty {
            if let tempCoverURL = await EBookParser.extractCover(from: url, href: coverItem) {
                defer { try? FileManager.default.removeItem(at: tempCoverURL) }
                if let data = try? Data(contentsOf: tempCoverURL), let image = UIImage(data: data) {
                    if !Self.isBlankOrSolidColorImage(image) && !Self.isSuspiciouslyLowRes(image) {
                        return image
                    }
                }
            }
        }
        
        // 2. Direct EPUB archive image search fallback
        let archiveCoverTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
            
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]
            var candidateEntries: [(path: String, entry: ZIPFoundation.Entry, size: UInt32)] = []
            
            for entry in archive {
                if entry.type == .directory { continue }
                let ext = (entry.path as NSString).pathExtension.lowercased()
                guard imageExts.contains(ext),
                      !entry.path.contains("__MACOSX"),
                      !(entry.path as NSString).lastPathComponent.hasPrefix("._"),
                      !entry.path.hasSuffix(".DS_Store"),
                      entry.uncompressedSize >= 5000
                else { continue }
                
                let filename = (entry.path as NSString).lastPathComponent.lowercased()
                if filename.contains("icon") || filename.contains("bullet") || filename.contains("spacer") || filename.contains("logo") || filename.contains("cross") {
                    continue
                }
                
                candidateEntries.append((entry.path, entry, entry.uncompressedSize))
            }
            
            let sortedCandidates = candidateEntries.sorted { a, b in
                let aPath = a.path.lowercased()
                let bPath = b.path.lowercased()
                let aIsCover = aPath.contains("cover")
                let bIsCover = bPath.contains("cover")
                if aIsCover != bIsCover { return aIsCover }
                let aIsFront = aPath.contains("front") || aPath.contains("title")
                let bIsFront = bPath.contains("front") || bPath.contains("title")
                if aIsFront != bIsFront { return aIsFront }
                return a.size > b.size
            }
            
            for candidate in sortedCandidates.prefix(6) {
                var data = Data()
                do {
                    _ = try archive.extract(candidate.entry) { data.append($0) }
                    if let image = UIImage(data: data) {
                        if !PhysicalFileSystemRouter.isBlankOrSolidColorImage(image) &&
                           !PhysicalFileSystemRouter.isSuspiciouslyLowRes(image) {
                            return image
                        }
                    }
                } catch {
                    continue
                }
            }
            return nil
        }
        if let archiveCover = await archiveCoverTask.value {
            return archiveCover
        }
        
        // 3. Typographic fallback
        return Self.generateTypographicCover(title: title, author: author)
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
        backfillTask?.cancel()
        
        let allPDFs = manager.convertedPDFs
        
        backfillTask = Task(priority: .userInitiated) {
            // Hop to Main Actor ONCE to filter pdfs that need warming
            let pdfsToWarm = await MainActor.run { () -> [ConvertedPDF] in
                allPDFs.filter { pdf in
                    let key = pdf.id.uuidString as NSString
                    return manager.thumbnailCache.object(forKey: key) == nil
                }
            }
            
            var warmedAny = false
            for pdf in pdfsToWarm {
                guard !Task.isCancelled else { return }
                
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
                        let key = pdf.id.uuidString as NSString
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
                manager.thumbnailReadySubject.send(pdf.id)
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
                    manager.thumbnailReadySubject.send(pdf.id)
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
    
    // MARK: - Disclaimer / Warning Image Filter & Image Quality Validators
    
    nonisolated static func isDisclaimerFilename(_ path: String) -> Bool {
        let filename = ((path as NSString).lastPathComponent).lowercased()
        let lowerPath = path.lowercased()
        
        let explicitKeywords = [
            "disclaimer", "warning", "notice", "piracy", "pirat", "illegal",
            "anti-piracy", "antipiracy", "rules", "watermark", "scanlation",
            "recruitment", "recruit", "cleaner", "typesetter",
            "shurim", "flamecomics", "flamescans", "asurascans", "asura",
            "reaperscans", "voidscans", "luminousscans", "discord",
            "patreon", "ko-fi", "kofi", "donation", "promo", "credit"
        ]
        
        for kw in explicitKeywords {
            if filename.contains(kw) || lowerPath.contains("/" + kw) {
                if !filename.contains("chapter") && !filename.contains("volume") && !filename.contains("page") {
                    return true
                }
                if kw == "disclaimer" || kw == "warning" || kw.contains("pirat") || kw == "illegal" {
                    return true
                }
            }
        }
        
        return false
    }
    
    nonisolated static func containsDisclaimerText(in image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        
        var detectedDisclaimer = false
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            let warningKeywords = [
                "pirat", "illegal", "ramification", "stipulated by",
                "offender", "captured and published", "scanlation", "scans",
                "join our discord", "discord.gg", "patreon", "ko-fi", "kofi",
                "do not repost", "do not upload", "upload to", "translated by",
                "recruitment", "support the author", "face the full extent",
                "legal ramifications", "be traced"
            ]
            
            for observation in observations {
                let candidates = observation.topCandidates(1)
                if let topText = candidates.first?.string.lowercased() {
                    for kw in warningKeywords {
                        if topText.contains(kw) {
                            detectedDisclaimer = true
                            return
                        }
                    }
                }
            }
        }
        
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        
        return detectedDisclaimer
    }
    
    nonisolated static func isBlankOrSolidColorImage(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        
        let width = 8
        let height = 8
        let bytesPerPixel = 1
        let bytesPerRow = width * bytesPerPixel
        var rawBytes = [UInt8](repeating: 0, count: width * height)
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &rawBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var minVal: UInt8 = 255
        var maxVal: UInt8 = 0
        var sum: Int = 0
        
        for byte in rawBytes {
            if byte < minVal { minVal = byte }
            if byte > maxVal { maxVal = byte }
            sum += Int(byte)
        }
        
        let range = Int(maxVal) - Int(minVal)
        let average = Double(sum) / Double(width * height)
        
        if range <= 8 {
            return true
        }
        if average >= 248 && range <= 18 {
            return true
        }
        if average <= 6 && range <= 18 {
            return true
        }
        
        return false
    }
    
    nonisolated static func isSuspiciouslyLowRes(_ image: UIImage) -> Bool {
        return image.size.width < 50 || image.size.height < 50
    }
    
    nonisolated static func generateTypographicCover(title: String, author: String) -> UIImage {
        let size = CGSize(width: 400, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let cgContext = context.cgContext
            
            let hash = abs(title.hashValue)
            let hue1 = CGFloat(hash % 360) / 360.0
            let color1 = UIColor(hue: hue1, saturation: 0.65, brightness: 0.35, alpha: 1.0)
            let color2 = UIColor(hue: hue1, saturation: 0.85, brightness: 0.15, alpha: 1.0)
            
            let colors = [color1.cgColor, color2.cgColor] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                cgContext.drawLinearGradient(gradient, start: CGPoint.zero, end: CGPoint(x: size.width, y: size.height), options: [])
            } else {
                color1.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            
            cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            cgContext.setLineWidth(2.0)
            cgContext.stroke(CGRect(x: 16, y: 16, width: size.width - 32, height: size.height - 32))
            
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 42, weight: .light)
            if let bookIcon = UIImage(systemName: "book.closed.fill", withConfiguration: iconConfig)?.withTintColor(UIColor.white.withAlphaComponent(0.4), renderingMode: .alwaysOriginal) {
                let iconRect = CGRect(x: (size.width - 50) / 2, y: 100, width: 50, height: 50)
                bookIcon.draw(in: iconRect)
            }
            
            let cleanTitle = title.isEmpty ? "Untitled Book" : title
            let titleParagraph = NSMutableParagraphStyle()
            titleParagraph.alignment = .center
            titleParagraph.lineBreakMode = .byWordWrapping
            
            let titleFont = UIFont.systemFont(ofSize: 26, weight: .bold)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: titleParagraph
            ]
            
            let titleRect = CGRect(x: 32, y: 190, width: size.width - 64, height: 240)
            (cleanTitle as NSString).draw(in: titleRect, withAttributes: titleAttrs)
            
            if !author.isEmpty {
                let authorParagraph = NSMutableParagraphStyle()
                authorParagraph.alignment = .center
                let authorFont = UIFont.systemFont(ofSize: 17, weight: .medium)
                let authorAttrs: [NSAttributedString.Key: Any] = [
                    .font: authorFont,
                    .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                    .paragraphStyle: authorParagraph
                ]
                let authorRect = CGRect(x: 32, y: size.height - 110, width: size.width - 64, height: 60)
                (author as NSString).draw(in: authorRect, withAttributes: authorAttrs)
            }
        }
    }
    
    nonisolated static func isSandboxURL(_ url: URL) -> Bool {
        let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        return resolvedPath.hasPrefix(homePath)
    }

    enum ArchiveFormat {
        case zip
        case rar
        case pdf
        case unknown
    }

    nonisolated static func detectFormat(at url: URL) -> ArchiveFormat {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? fileHandle.close() }
        
        guard let data = try? fileHandle.read(upToCount: 4) else { return .unknown }
        if data.count < 4 { return .unknown }
        
        let bytes = [UInt8](data)
        if bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04 {
            return .zip
        }
        if bytes[0] == 0x52 && bytes[1] == 0x61 && bytes[2] == 0x72 && bytes[3] == 0x21 {
            return .rar
        }
        if bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 {
            return .pdf
        }
        return .unknown
    }

    nonisolated static func extractCoverImageStatic(from url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        let detected = detectFormat(at: url)
        
        let isPDF = detected == .pdf || (detected == .unknown && ext == "pdf")
        let isZIP = detected == .zip || (detected == .unknown && ["cbz", "zip", "epub"].contains(ext))
        let isRAR = detected == .rar || (detected == .unknown && (ext == "cbr" || ext == "rar"))
        let isCBT = ext == "cbt" || ext == "tar"

        if isPDF {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            return autoreleasepool { () -> UIImage? in
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
                
                // Try up to the first 8 pages to find a portrait cover
                var firstSpreadImage: UIImage? = nil
                for i in 0..<min(document.pageCount, 8) {
                    let pageImage = autoreleasepool { () -> UIImage? in
                        guard let page = document.page(at: i) else { return nil }
                        let bounds = page.bounds(for: .mediaBox)
                        // Skip landscape (two-page spread)
                        if bounds.width > bounds.height && document.pageCount > 1 {
                            return drawPage(page)
                        }
                        if let portrait = drawPage(page) {
                            if PhysicalFileSystemRouter.isSuspiciouslyLowRes(portrait) { return nil }
                            if PhysicalFileSystemRouter.containsDisclaimerText(in: portrait) {
                                Logger.shared.log("[Disclaimer Detector] Skipping PDF page \(i) due to disclaimer/warning text.", category: "FileSystem", type: .warning)
                                return nil
                            }
                            if PhysicalFileSystemRouter.isBlankOrSolidColorImage(portrait) {
                                Logger.shared.log("[Blank Detector] Skipping PDF page \(i) due to blank/solid color.", category: "FileSystem", type: .warning)
                                return nil
                            }
                            return portrait
                        }
                        return nil
                    }
                    
                    if let img = pageImage {
                        if let page = document.page(at: i) {
                            let bounds = page.bounds(for: .mediaBox)
                            if bounds.width > bounds.height && document.pageCount > 1 {
                                if firstSpreadImage == nil { firstSpreadImage = img }
                            } else {
                                return img
                            }
                        }
                    }
                }
                
                // Fallback to the first spread, or page 0 if nothing else worked
                if let fallback = firstSpreadImage { return fallback }
                if let page = document.page(at: 0) {
                    return drawPage(page)
                }
                return nil
            }
        }

        if isZIP {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            
            do {
                let archive = try Archive(url: url, accessMode: .read)

                let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "jfif"]
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
                
                // Prioritize explicit cover images (e.g. cover.jpg, OEBPS/images/cover.jpeg, cover-image.png)
                let coverMatches = imageEntries.filter { (path, _) in
                    let filename = (path as NSString).lastPathComponent.lowercased()
                    return filename.contains("cover")
                }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                
                let nonCoverMatches = imageEntries.filter { (path, _) in
                    let filename = (path as NSString).lastPathComponent.lowercased()
                    return !filename.contains("cover")
                }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                
                imageEntries = coverMatches + nonCoverMatches

                var firstSpreadImage: UIImage? = nil
                for (path, entry) in imageEntries.prefix(10) {
                    if PhysicalFileSystemRouter.isDisclaimerFilename(path) {
                        Logger.shared.log("[Disclaimer Detector] Skipping ZIP entry '\(path)' due to disclaimer filename.", category: "FileSystem", type: .warning)
                        continue
                    }
                    
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
                                let img = UIImage(cgImage: cg)
                                if PhysicalFileSystemRouter.isSuspiciouslyLowRes(img) {
                                    return nil
                                }
                                if PhysicalFileSystemRouter.containsDisclaimerText(in: img) {
                                    Logger.shared.log("[Disclaimer Detector] Skipping ZIP entry '\(entry.path)' due to disclaimer/warning text content.", category: "FileSystem", type: .warning)
                                    return nil
                                }
                                if PhysicalFileSystemRouter.isBlankOrSolidColorImage(img) {
                                    Logger.shared.log("[Blank Detector] Skipping ZIP entry '\(entry.path)' due to blank/solid color.", category: "FileSystem", type: .warning)
                                    return nil
                                }
                                return img
                            }
                            return nil
                        } catch {
                            Logger.shared.log("Failed to extract \(entry.path): \(error.localizedDescription)", category: "Archive", type: .warning)
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
                Logger.shared.log("Failed to extract archive: \(error.localizedDescription)", category: "Archive", type: .warning)
            }
        }
        if isRAR {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
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
                    for entry in sorted.prefix(10) {
                        if PhysicalFileSystemRouter.isDisclaimerFilename(entry.fileName) {
                            Logger.shared.log("[Disclaimer Detector] Skipping CBR entry '\(entry.fileName)' due to disclaimer filename.", category: "FileSystem", type: .warning)
                            continue
                        }

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
                                    let img = UIImage(cgImage: cg)
                                    if PhysicalFileSystemRouter.isSuspiciouslyLowRes(img) {
                                        return nil
                                    }
                                    if PhysicalFileSystemRouter.containsDisclaimerText(in: img) {
                                        Logger.shared.log("[Disclaimer Detector] Skipping CBR entry '\(entry.fileName)' due to disclaimer/warning text content.", category: "FileSystem", type: .warning)
                                        return nil
                                    }
                                    if PhysicalFileSystemRouter.isBlankOrSolidColorImage(img) {
                                        Logger.shared.log("[Blank Detector] Skipping CBR entry '\(entry.fileName)' due to blank/solid color.", category: "FileSystem", type: .warning)
                                        return nil
                                    }
                                    return img
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
                    Logger.shared.log("PhysicalFileSystemRouter: CBR cover extraction failed for '\(url.lastPathComponent)': \(error.localizedDescription)", category: "Archive", type: .warning)
                    return nil
                }
            }
        }

        if isCBT {
            return CBTExtractor.extractFirstImage(from: url)
        }

        return nil
    }
    
    nonisolated static func getPageCountStatic(from url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        let detected = detectFormat(at: url)
        
        let isPDF = detected == .pdf || (detected == .unknown && ext == "pdf")
        let isZIP = detected == .zip || (detected == .unknown && ["cbz", "zip", "epub"].contains(ext))
        let isRAR = detected == .rar || (detected == .unknown && (ext == "cbr" || ext == "rar"))
        let isCBT = ext == "cbt" || ext == "tar"

        if isPDF {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            return PDFDocument(url: url)?.pageCount ?? 0
        }

        if isZIP {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            
            if ext == "epub" {
                // Parse EPUB spine count synchronously
                do {
                    let archive = try Archive(url: url, accessMode: .read)
                    
                    // 1. Read META-INF/container.xml
                    var containerData = Data()
                    if let containerEntry = archive["META-INF/container.xml"] {
                        _ = try archive.extract(containerEntry) { chunk in containerData.append(chunk) }
                    } else {
                        // case-insensitive fallback
                        for entry in archive {
                            if entry.path.lowercased() == "meta-inf/container.xml" {
                                _ = try archive.extract(entry) { chunk in containerData.append(chunk) }
                                break
                            }
                        }
                    }
                    
                    if !containerData.isEmpty {
                        let containerParser = MiniXMLParser(data: containerData)
                        if let opfPath = containerParser.firstAttributeValue(tag: "rootfile", attribute: "full-path") {
                            // 2. Read OPF
                            var opfData = Data()
                            let cleanOpfPath = opfPath.hasPrefix("/") ? String(opfPath.dropFirst()) : opfPath
                            if let opfEntry = archive[cleanOpfPath] {
                                _ = try archive.extract(opfEntry) { chunk in opfData.append(chunk) }
                            } else {
                                let lowerOpf = cleanOpfPath.lowercased()
                                for entry in archive {
                                    if entry.path.lowercased() == lowerOpf || entry.path.lowercased().hasSuffix(lowerOpf) {
                                        _ = try archive.extract(entry) { chunk in opfData.append(chunk) }
                                        break
                                    }
                                }
                            }
                            
                            if !opfData.isEmpty {
                                let opfParser = MiniXMLParser(data: opfData)
                                let spineIds = opfParser.spineItemRefs()
                                if !spineIds.isEmpty {
                                    return spineIds.count
                                }
                            }
                        }
                    }
                } catch {
                    Logger.shared.log("EPUB page count parsing failed: \(error.localizedDescription)", category: "Archive", type: .warning)
                }
            }
            
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
                Logger.shared.log("Failed to count pages in archive: \(error.localizedDescription)", category: "Archive", type: .warning)
            }
            return 0
        }

        // ── CBR / RAR Archives ─────────────────────────────────────────────────
        if isRAR {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
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
                    Logger.shared.log("PhysicalFileSystemRouter: CBR page count failed for '\(url.lastPathComponent)': \(error.localizedDescription)", category: "Archive", type: .warning)
                    return 0
                }
            }
        }

        if isCBT {
            return CBTExtractor.getPageCount(from: url)
        }

        return 0
    }
    
    nonisolated static func extractPageImage(from url: URL, pageIndex: Int) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
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
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
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
            let accessing = !isSandboxURL(url) ? url.startAccessingSecurityScopedResource() : false
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
    private var failedIDs: Set<UUID> = []
    private var activeCount = 0
    private let maxConcurrent = 2
    
    func enqueue(_ pdf: ConvertedPDF, manager: ConversionManager) {
        // Prevent duplicate queuing for the same file
        guard !failedIDs.contains(pdf.id) else { return }
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
            
            let key = pdf.id.uuidString as NSString
            let cached = await MainActor.run { manager.thumbnailCache.object(forKey: key) != nil }
            var onDisk = false
            if let url = await PhysicalFileSystemRouter.shared.getCoverURL(for: pdf) {
                onDisk = FileManager.default.fileExists(atPath: url.path)
            }
            let success = cached || onDisk
            
            await ThumbnailGenerationQueue.shared.taskDidFinish(id: pdf.id, success: success)
        }
    }
    
    func taskDidFinish(id: UUID, success: Bool) {
        activeCount -= 1
        inFlight.remove(id)
        if !success {
            failedIDs.insert(id)
        }
        dequeue()
    }
    
    func generateThumbnail(for pdf: ConvertedPDF, in manager: ConversionManager) async -> UIImage? {
        await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: manager)
        let key = pdf.id.uuidString as NSString
        return await MainActor.run { manager.thumbnailCache.object(forKey: key) }
    }
}

