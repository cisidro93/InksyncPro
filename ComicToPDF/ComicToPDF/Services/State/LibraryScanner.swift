import Foundation
import UIKit
import Combine
import ZIPFoundation
import SwiftUI
import PDFKit
import Unrar

/// Resolves the 'God Object' bottleneck by handling intensive O(N) file system
/// enumeration strictly off the Main Thread.
actor LibraryScanner {
    static let shared = LibraryScanner()

    private var isScanning = false
    private var needsScanAgain = false
    private var pendingMode: AppUIMode?

    func scanLibrary(addedByMode: AppUIMode? = nil, manager: ConversionManager) async {
        if isScanning {
            needsScanAgain = true
            if let mode = addedByMode {
                pendingMode = mode
            }
            return
        }
        
        isScanning = true
        needsScanAgain = false
        let modeToUse = addedByMode ?? pendingMode
        pendingMode = nil
        
        await performScan(addedByMode: modeToUse, manager: manager)
        
        isScanning = false
        
        if needsScanAgain {
            await scanLibrary(addedByMode: nil, manager: manager)
        }
    }

    private func performScan(addedByMode: AppUIMode? = nil, manager: ConversionManager) async {

        let fileManager = FileManager.default
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let inboxDir  = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        let docDir    = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory

        // Ensure SharedImportCoordinator processes any staged files first
        await SharedImportCoordinator.shared.coordinateImportDirect()

        func normalizeFilename(_ raw: String) -> String {
            let decoded = raw.removingPercentEncoding ?? raw
            return decoded.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func relativePath(for url: URL) -> String {
            let path = url.path.removingPercentEncoding ?? url.path
            if let range = path.range(of: "/Documents/", options: .caseInsensitive) {
                return "Documents/" + String(path[range.upperBound...]).lowercased()
            }
            if let range = path.range(of: "/InksyncVault/Inbox/", options: .caseInsensitive) {
                return "Inbox/" + String(path[range.upperBound...]).lowercased()
            }
            return normalizeFilename(url.lastPathComponent)
        }

        var newPDFs: [ConvertedPDF] = []
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]

        var (existingRelPaths, existingCanonicalPaths, existingFilenames) = await MainActor.run {
            var rels = Set<String>()
            var paths = Set<String>()
            var filenames = Set<String>()
            
            for pdf in manager.convertedPDFs {
                if pdf.isLinked {
                    paths.insert(pdf.url.path.lowercased())
                } else {
                    rels.insert(relativePath(for: pdf.url))
                }
                paths.insert(pdf.url.resolvingSymlinksInPath().path.lowercased())
                let fn = normalizeFilename(pdf.url.lastPathComponent)
                filenames.insert(fn)
            }
            return (rels, paths, filenames)
        }

        // Scan Documents directory and InksyncVault Inbox
        let dirsToScan = [docDir, inboxDir]

        for scanDir in dirsToScan {
            guard let enumerator = fileManager.enumerator(
                at: scanDir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }

            var filesSinceYield = 0
            while let fileURL = enumerator.nextObject() as? URL {
                filesSinceYield += 1
                if filesSinceYield >= 25 {
                    filesSinceYield = 0
                    await Task.yield()
                }

                if fileURL.path.contains("Recovered_Vault") || fileURL.path.contains("LibraryVault") { continue }

                let ext = fileURL.pathExtension.lowercased()
                guard ["pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip"].contains(ext) else { continue }

                let filename = normalizeFilename(fileURL.lastPathComponent)
                let relPath = relativePath(for: fileURL)
                let canonicalPath = fileURL.resolvingSymlinksInPath().path.lowercased()
                
                // Exact path-based duplicate protection: Skip if this exact file is already loaded in memory
                if existingRelPaths.contains(relPath) || existingCanonicalPaths.contains(canonicalPath) {
                    continue
                }
                
                // Track newly discovered file in set so intra-pass duplicates across folders are prevented:
                existingRelPaths.insert(relPath)
                existingCanonicalPaths.insert(canonicalPath)
                existingFilenames.insert(filename)
                
                // Skip files currently being uploaded via WiFi
                guard !ActiveUploadRegistry.shared.isUploading(fileURL) else { continue }

                // File integrity check to prevent premature ingestion of incomplete files
                guard isFileCompleteAndValid(at: fileURL) else {
                    Logger.shared.log("LibraryScanner: Skipping scan of incomplete or unreadable file: \(filename)", category: "Library", type: .warning)
                    continue
                }

                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

                let inferredContentType = MetadataHeuristics.detectAsymmetricContentType(url: fileURL)

                let parentName = fileURL.deletingLastPathComponent().lastPathComponent
                let invalidParents = ["documents", "inbox", "tmp", "caches", "file provider storage", "downloads", "inksyncstaging_", "folder_spider_", "folderspider_"]
                var seriesName: String? = nil
                if !invalidParents.contains(where: { parentName.lowercased().hasPrefix($0) }) && parentName.count > 2 && UUID(uuidString: parentName) == nil {
                    seriesName = parentName
                }

                let parsedTokens = DeterministicFilenameParser.parse(filename: filename)
                let fallbackSeries = parsedTokens.seriesName.isEmpty ? (seriesName ?? "Unknown") : parsedTokens.seriesName
                var metadata = PDFMetadata(title: parsedTokens.title ?? filename)
                metadata.series = fallbackSeries
                metadata.volume = parsedTokens.volume
                metadata.issueNumber = parsedTokens.issueNumber
                
                // Fallback to smart filename extraction if series is still missing/empty
                if metadata.series == nil || metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    let parsedSeries = SeriesNameParser.cleanFolderName(MetadataHeuristics.cleanFilename(filename))
                    if !parsedSeries.isEmpty {
                        metadata.series = parsedSeries
                    }
                }

                var finalContentType = inferredContentType
                let isArchive = ["cbz", "zip"].contains(ext)
                if isArchive {
                    if let parsedInfo = ComicInfoParser.parse(from: fileURL) {
                        metadata.isManga = parsedInfo.manga
                        if parsedInfo.manga {
                            finalContentType = .manga
                        }
                        if let parsedSeries = parsedInfo.series, !parsedSeries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            metadata.series = parsedSeries
                        }
                        if let parsedTitle = parsedInfo.title, !parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            metadata.title = parsedTitle
                        }
                        if let parsedNum = parsedInfo.number {
                            metadata.issueNumber = parsedNum
                        }
                        if let parsedVolume = parsedInfo.volume {
                            metadata.volume = String(parsedVolume)
                        }
                        if let writer = parsedInfo.writer {
                            metadata.writer = writer
                        }
                        if let penciller = parsedInfo.penciller {
                            metadata.penciller = penciller
                        }
                        if let inker = parsedInfo.inker {
                            metadata.inker = inker
                        }
                        if let colorist = parsedInfo.colorist {
                            metadata.colorist = colorist
                        }
                        if let letterer = parsedInfo.letterer {
                            metadata.letterer = letterer
                        }
                        if let coverArtist = parsedInfo.coverArtist {
                            metadata.coverArtist = coverArtist
                        }
                        if let editor = parsedInfo.editor {
                            metadata.editor = editor
                        }
                        if let characters = parsedInfo.characters {
                            metadata.characters = characters
                        }
                        if let genre = parsedInfo.genre {
                            metadata.genre = genre
                        }
                        if let ageRating = parsedInfo.ageRating {
                            metadata.ageRating = ageRating
                        }
                        if let web = parsedInfo.web {
                            metadata.web = web
                        }
                        if let publisher = parsedInfo.publisher {
                            metadata.publisher = publisher
                        }
                        if let summary = parsedInfo.summary {
                            metadata.summary = summary
                        }
                        for tag in parsedInfo.tags {
                            if !metadata.tags.contains(tag) { metadata.tags.append(tag) }
                        }
                    }
                }

                let cleanTitle = fileURL.deletingPathExtension().lastPathComponent
                var displayName = cleanTitle.isEmpty ? fileURL.lastPathComponent : cleanTitle
                if fileURL.pathExtension.lowercased() == "pdf" {
                    if let recoveredTitle = await MainActor.run(body: { PDFTitleRecoverer.recoverPDFTitle(from: fileURL) }) {
                        displayName = recoveredTitle
                    }
                }
                var newPDF = ConvertedPDF(
                    name: displayName, url: fileURL,
                    pageCount: 0, fileSize: fileSize,
                    metadata: metadata,
                    contentType: finalContentType
                )
                newPDF.addedByMode = addedByMode ?? .pro
                newPDFs.append(newPDF)
            }
        }

        let finalNewPDFs = newPDFs
        if !finalNewPDFs.isEmpty {
            await MainActor.run {
                manager.convertedPDFs.append(contentsOf: finalNewPDFs)
                Logger.shared.log("Library Scanned: Found \(finalNewPDFs.count) new files (mode: \(addedByMode?.rawValue ?? "Pro"))", category: "Library")
                manager.saveLibrary()
            }
            await LibraryService.shared.runSmartGrouping()
        }

        // ── Cover + page-count backfill ──────────────────────────────────────
        // ✅ PERF: Was serial — one cover then one page count, one file at a time.
        // Now uses a TaskGroup capped at 4 concurrent slots.
        // Each slot fetches the cover and page count for one file, then the slot
        // opens for the next file. This keeps CPU/IO busy without flooding the
        // main actor queue with 500 simultaneous tasks.

        let pdfsToProcess = await MainActor.run {
            manager.convertedPDFs.filter { $0.pageCount == 0 }
        }

        if !pdfsToProcess.isEmpty {
            // Materialise the work list as a plain value-type array before crossing into
            // Task.detached isolation.
            let workItems: [(id: UUID, url: URL)] = pdfsToProcess
                .filter { !ActiveUploadRegistry.shared.isUploading($0.url) }
                .map { ($0.id, $0.url) }
            let perfClass = ProcessInfo.processInfo.performanceClass
            let maxConcurrency = perfClass == .low ? 2 : 4

            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                await withTaskGroup(of: BackfillResult?.self) { group in
                    var nextIndex = 0

                    func enqueueNext() {
                        guard nextIndex < workItems.count else { return }
                        let item = workItems[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            let image = PhysicalFileSystemRouter.extractCoverImageStatic(from: item.url)
                            let jpegData = image?.jpegData(compressionQuality: 0.7)
                            let count = PhysicalFileSystemRouter.getPageCountStatic(from: item.url)
                            return BackfillResult(id: item.id, pageCount: count, coverData: jpegData)
                        }
                    }

                    for _ in 0..<min(maxConcurrency, workItems.count) { enqueueNext() }

                    var results: [BackfillResult] = []
                    for await result in group {
                        if let res = result {
                            results.append(res)
                            
                            // Apply in batches of 10 to keep progress moving without rapid UI updates
                            if results.count >= 10 {
                                let batch = results
                                results.removeAll()
                                await self.applyMetadataBatch(batch, manager: manager)
                            }
                        }
                        enqueueNext()
                    }
                    
                    if !results.isEmpty {
                        await self.applyMetadataBatch(results, manager: manager)
                    }
                }
            }
        }

        // ── Deduplication & ghost-file pruning ───────────────────────────────
        let allPDFs = await MainActor.run { manager.convertedPDFs }
        
        var seenPaths = Set<String>()
        var missingIDs = Set<UUID>()
        var repairedURLs: [UUID: URL] = [:]

        // PERF D-M1: yield every 50 files so iCloud-backed fileExists calls
        // (which can block waiting for ubiquity metadata) don't stall the actor
        // thread and delay the first library render.
        var pruneYieldCount = 0
        for pdf in allPDFs {
            pruneYieldCount += 1
            if pruneYieldCount % 50 == 0 { await Task.yield() }

            if pdf.isLinked {
                if seenPaths.contains(pdf.url.path) {
                    missingIDs.insert(pdf.id)
                    continue
                }
                seenPaths.insert(pdf.url.path)
                continue
            }

            var resolvedURL = pdf.url
            var didRepair = false

            if !fileManager.fileExists(atPath: pdf.url.path) {
                // Sandbox-Shift Repair Logic
                let oldPath = pdf.url.path
                if let docRange = oldPath.range(of: "/Documents/") {
                    let relPath = String(oldPath[docRange.upperBound...])
                    let checkURL = docDir.appendingPathComponent(relPath)
                    if fileManager.fileExists(atPath: checkURL.path) {
                        resolvedURL = checkURL
                        didRepair = true
                    }
                }
                if !didRepair, let inboxRange = oldPath.range(of: "/InksyncVault/Inbox/") {
                    let relPath = String(oldPath[inboxRange.upperBound...])
                    let checkURL = inboxDir.appendingPathComponent(relPath)
                    if fileManager.fileExists(atPath: checkURL.path) {
                        resolvedURL = checkURL
                        didRepair = true
                    }
                }
                // Fallback: Check root of Documents and Inbox
                if !didRepair {
                    let rootDoc = docDir.appendingPathComponent(pdf.url.lastPathComponent)
                    let rootInbox = inboxDir.appendingPathComponent(pdf.url.lastPathComponent)
                    if fileManager.fileExists(atPath: rootDoc.path) {
                        resolvedURL = rootDoc
                        didRepair = true
                    } else if fileManager.fileExists(atPath: rootInbox.path) {
                        resolvedURL = rootInbox
                        didRepair = true
                    }
                }
            }

            if didRepair {
                repairedURLs[pdf.id] = resolvedURL
            }

            if seenPaths.contains(resolvedURL.path) {
                missingIDs.insert(pdf.id)
                continue
            }

            if fileManager.fileExists(atPath: resolvedURL.path) {
                seenPaths.insert(resolvedURL.path)
            } else {
                missingIDs.insert(pdf.id)
            }
        }

        let requiresPrune = !missingIDs.isEmpty || !repairedURLs.isEmpty
        if requiresPrune {
            await MainActor.run {
                if !missingIDs.isEmpty {
                    manager.convertedPDFs.removeAll { missingIDs.contains($0.id) }
                }
                for (id, url) in repairedURLs {
                    if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == id }) {
                        manager.convertedPDFs[idx].url = url
                    }
                }
                manager.pruneEmptyCollections()
                Logger.shared.log("Library Pruned: Repaired \(repairedURLs.count) sandbox-shifted URLs and removed \(missingIDs.count) missing files", category: "Library")
                manager.saveLibrary()
            }
        }
    }

    struct BackfillResult: Sendable {
        let id: UUID
        let pageCount: Int
        let coverData: Data?
    }

    private func applyMetadataBatch(_ batch: [BackfillResult], manager: ConversionManager) async {
        await MainActor.run {
            var modified = manager.convertedPDFs
            for item in batch {
                if let idx = modified.firstIndex(where: { $0.id == item.id }) {
                    if item.pageCount > 0 {
                        modified[idx].pageCount = item.pageCount
                    } else {
                        Logger.shared.log("LibraryScanner: Backfill page count failed for \(modified[idx].name) — leaving at 0 for retry", category: "Library", type: .warning)
                    }
                    if let coverData = item.coverData {
                        // Clear ThumbnailDaemon cache
                        let pdfID = item.id
                        Task {
                            await ThumbnailDaemon.shared.clearCache(for: pdfID)
                        }
                        
                        // Write cover image to disk in a separate background thread
                        if let coverURL = PhysicalFileSystemRouter.shared.getCoverURL(for: modified[idx]) {
                            Task.detached(priority: .background) {
                                try? coverData.write(to: coverURL)
                            }
                        }
                        
                        let key = pdfID.uuidString as NSString
                        if let image = UIImage(data: coverData) {
                            let thumbnail = image.preparingThumbnail(of: CGSize(width: 300, height: 450)) ?? image
                            let cost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
                            manager.thumbnailCache.setObject(thumbnail, forKey: key, cost: cost)
                        }
                        modified[idx].coverImageData = nil
                        manager.thumbnailReadySubject.send(pdfID)
                    }
                }
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                manager.convertedPDFs = modified
            }
            manager.saveLibrary()
        }
    }

    // MARK: - File Integrity Verification

    private func isFileCompleteAndValid(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 32 else { return false }
        
        switch ext {
        case "pdf":
            if let doc = PDFDocument(url: url) {
                return doc.pageCount > 0 || doc.isLocked
            }
            // If PDFDocument fails initially, allow if magic bytes start with %PDF
            if let fh = try? FileHandle(forReadingFrom: url),
               let data = try? fh.read(upToCount: 4) {
                try? fh.close()
                return data.starts(with: [0x25, 0x50, 0x44, 0x46])
            }
            return false
        case "cbz", "zip", "epub":
            // Check zip header (PK..)
            if let fh = try? FileHandle(forReadingFrom: url),
               let data = try? fh.read(upToCount: 4) {
                try? fh.close()
                if data.starts(with: [0x50, 0x4B]) { return true }
            }
            return true
        case "cbr", "rar":
            return true
        default:
            return true
        }
    }

    // MARK: - Magic Byte Detection Helpers

    private func isSupportedSharedFile(_ fileURL: URL) -> Bool {
        return detectExtensionFromMagicBytes(fileURL) != nil
    }

    private func detectExtensionFromMagicBytes(_ fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let data = try? fileHandle.read(upToCount: 2000) else { return nil }
        defer { try? fileHandle.close() }
        guard data.count >= 4 else { return nil }

        // PDF (%PDF)
        if data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46 { return "pdf" }
        // RAR (Rar!)
        if data[0] == 0x52 && data[1] == 0x61 && data[2] == 0x72 && data[3] == 0x21 { return "cbr" }
        // ZIP / CBZ / EPUB (PK\x03\x04 or PK\x05\x06)
        if (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04) ||
           (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x05 && data[3] == 0x06) {
            let header = String(decoding: data.prefix(500), as: UTF8.self)
            if header.contains("mimetype") && (header.contains("epub+zip") || header.contains("epub")) {
                return "epub"
            }
            return "cbz"
        }
        return nil
    }
}
