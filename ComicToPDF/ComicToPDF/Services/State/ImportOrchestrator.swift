import Foundation
import ZIPFoundation
import SwiftUI

/// A dedicated Orchestrator that natively extracts and inherits the incredibly heavy background operations required to parse multi-gigabyte ZIP/CBZ streams and PDF pages cleanly without tying up the Application's main Presentation state object.
actor ImportOrchestrator {
    static let shared = ImportOrchestrator()
    private init() {}
    

    private func detectDocumentSubtype(url: URL, fileSize: Int64) -> DocumentSubtype {
        let name = url.lastPathComponent.lowercased()
        let isLargeFile = fileSize > 10 * 1024 * 1024
        
        if name.contains("arxiv") || name.contains("doi") || name.contains("paper") {
            return .researchPaper
        }
        
        if isLargeFile && (name.contains("mag") || name.contains("issue")) {
            return .magazine
        }
        
        if name.contains("manual") || name.contains("guide") {
            return .manual
        }
        
        return .unknown
    }
    
    func importFolderStructure(from folderURL: URL, manager: ConversionManager) async {
        await MainActor.run { manager.isConverting = true; manager.processingStatus = "Preparing Folder Sync..." }
        defer { Task { await MainActor.run { manager.isConverting = false; manager.processingStatus = "" } } }
        
        let existingPaths = await MainActor.run { Set(manager.convertedPDFs.map { $0.url.lastPathComponent }) }

        let newPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
            
            do {
                let bookmarkData = try folderURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                await MainActor.run {
                    if !AppSettingsManager.shared.watchedFolders.contains(where: { $0.bookmarkData == bookmarkData }) {
                        let watched = AppSettingsManager.WatchedFolder(name: folderURL.lastPathComponent, bookmarkData: bookmarkData)
                        AppSettingsManager.shared.watchedFolders.append(watched)
                        AppSettingsManager.shared.save()
                    }
                }
            } catch {
                Logger.shared.log("Note: Could not create persistent bookmark for folder: \(error.localizedDescription). Reverting to one-time copy.", category: "Import")
            }
            
            let fileManager = FileManager.default
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            var newlyImported: [ConvertedPDF] = []
            
            await MainActor.run { manager.processingStatus = "Scanning \(folderURL.lastPathComponent)..." }
            
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
            
            // O(1) in-batch dedup — avoids O(n²) newlyImported.contains(where:) scan
            var batchFileNames = Set<String>()
            var fileCount = 0
            while let fileURL = enumerator.nextObject() as? URL {
                fileCount += 1
                if fileCount % 25 == 0 {
                    let currentCount = fileCount
                    await MainActor.run { manager.processingStatus = "Scanning \(folderURL.lastPathComponent) (\(currentCount) items)..." }
                    await Task.yield()
                }
                
                guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                      let isDirectory = resourceValues.isDirectory, !isDirectory else { continue }
                
                let ext = fileURL.pathExtension.lowercased()
                guard ["cbz", "zip", "epub"].contains(ext) else { continue }
                
                let fileName = fileURL.lastPathComponent
                let destURL = documentsDir.appendingPathComponent(fileName)
                
                // O(1) dedup using pre-built sets (FIX: was O(n) contains(where:) per file)
                guard !existingPaths.contains(fileName) && !batchFileNames.contains(fileName) else { continue }
                
                do {
                    await MainActor.run { manager.processingStatus = "Importing \(fileName)..." }
                    if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                    try fileManager.copyItem(at: fileURL, to: destURL)
                    
                    // FIX: read size from enumerator's pre-fetched resourceValues — saves one attributesOfItem syscall per file
                    let size = resourceValues.fileSize.map(Int64.init) ?? 0
                    
                    let seriesName = fileURL.deletingLastPathComponent().lastPathComponent
                    var smartDisplayName = fileName
                    var smartMetadata = PDFMetadata(title: fileName)
                    smartMetadata.series = seriesName
                    
                    let cType = MetadataHeuristics.detectAsymmetricContentType(url: destURL)
                    
                    // FIX: Single ZIP open — previously called fetchNonDestructiveMetadata AND
                    // ComicInfoParser.parse separately, each re-opening the archive.
                    let isArchive = ["cbz", "zip"].contains(ext)
                    
                    var xmlData: (displayName: String, parsedSeries: String?, parsedNumber: String?, parsedVolume: String?, parsedTitle: String?)?
                    var parsedInfo: ComicInfoParser.ComicInfo?
                    let pdfID = UUID()
                    
                    autoreleasepool {
                        xmlData = isArchive ? (try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: destURL)) : nil
                        parsedInfo = isArchive ? ComicInfoParser.parse(from: destURL) : nil
                        
                        if let img = PhysicalFileSystemRouter.extractCoverImageStatic(from: destURL),
                           let jpegData = img.jpegData(compressionQuality: 0.7) {
                            let coversDir = PhysicalFileSystemRouter.getCoversDirectory()
                            let coverURL = coversDir.appendingPathComponent("cover_\(pdfID.uuidString).jpg")
                            try? jpegData.write(to: coverURL)
                        }
                    }

                    if let xmlData = xmlData {
                        smartDisplayName = xmlData.displayName
                        smartMetadata.title = xmlData.parsedTitle ?? smartDisplayName
                        smartMetadata.series = xmlData.parsedSeries ?? seriesName
                        smartMetadata.issueNumber = xmlData.parsedNumber
                        smartMetadata.tags.append("Auto XML Scrape")
                    }

                    if let parsedInfo = parsedInfo {
                        smartMetadata.isManga = parsedInfo.manga
                        if xmlData == nil {
                            smartMetadata.title = parsedInfo.title ?? smartDisplayName
                            smartMetadata.series = parsedInfo.series ?? seriesName
                            smartMetadata.issueNumber = parsedInfo.number
                            smartMetadata.writer = parsedInfo.writer
                            smartMetadata.publisher = parsedInfo.publisher
                            smartMetadata.summary = parsedInfo.summary
                            if let year = parsedInfo.year {
                                var comps = DateComponents()
                                comps.year = year; comps.month = 1; comps.day = 1
                                smartMetadata.publicationDate = Calendar.current.date(from: comps)
                            }
                            for tag in parsedInfo.tags {
                                if !smartMetadata.tags.contains(tag) { smartMetadata.tags.append(tag) }
                            }
                        }
                    } else if xmlData == nil {
                        smartMetadata.title = smartDisplayName
                        smartMetadata.series = seriesName
                    }

                    var pdf = ConvertedPDF(
                        id: pdfID,
                        name: smartDisplayName,
                        url: destURL,
                        pageCount: 0,
                        fileSize: size,
                        metadata: smartMetadata,
                        contentType: cType
                    )
                    if pdf.contentType == .hybrid || pdf.contentType == .book {
                        pdf.documentSubtype = await self.detectDocumentSubtype(url: destURL, fileSize: size)
                    }
                    batchFileNames.insert(fileName)
                    newlyImported.append(pdf)
                } catch {
                    Logger.shared.log("Failed to sync \(fileName): \(error.localizedDescription)", category: "Import", type: .error)
                }
            }
            return newlyImported
        }.value
        
        await MainActor.run {
            for pdf in newPDFs {
                manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                manager.convertedPDFs.append(pdf)
            }
            manager.saveLibrary()
        }
    }
    
    func importFilesAsSeries(urls: [URL], manager: ConversionManager, overrides: [URL: PDFMetadata] = [:]) async -> [ConvertedPDF] {
        await MainActor.run { manager.isConverting = true; manager.processingStatus = "Preparing Import..." }
        defer { Task { await MainActor.run { manager.isConverting = false; manager.processingStatus = "" } } }
        
        // ── Smart Duplicate Fingerprinting ──────────────────────────────────────────
        // Build TWO lookup sets from the live library (both sourced from the model, not disk):
        //   1. existingKeys   → "filename||size"  — exact identity (same name + same bytes)
        //   2. existingSizes  → Int64 set          — size fingerprint (catches renames of same file)
        // A file is a "true duplicate" only when BOTH its name AND size match the library.
        // A file is a "size clone" when its size appears in the library (likely a renamed copy).
        // New files (neither match) are always imported.
        let existingKeys: Set<String> = await MainActor.run {
            Set(manager.convertedPDFs.map { "\($0.url.lastPathComponent)||\($0.fileSize)" })
        }
        let existingPaths = await MainActor.run { Set(manager.convertedPDFs.map { $0.url.lastPathComponent }) }
        let isVaultUnlocked = await MainActor.run { !SecurityManager.shared.isVaultLocked }

        await MainActor.run { ImportMonitorManager.shared.startImport(totalCount: urls.count) }
        
        let importedPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            let fileManager = FileManager.default
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            var newPDFs: [ConvertedPDF] = []
            var unstoredPDFs: [ConvertedPDF] = []

            // O(1) in-batch dedup set — replaces the O(n²) newPDFs.contains(where:) scan
            var batchKeys = Set<String>()        // "filename||size"
            var batchFileNames = Set<String>()   // filename only (for collision rename logic)

            var loopIndex = 0
            for url in urls {
                loopIndex += 1
                // Yield every 50 files — enough to breathe without 1400 individual MainActor trips
                if loopIndex % 50 == 0 {
                    await Task.yield()
                    let idx = loopIndex
                    await MainActor.run { manager.processingStatus = "Importing \(idx) of \(urls.count)…" }
                }
                
                if await ImportMonitorManager.shared.isCancelled {
                    Logger.shared.log("Import cancelled by user mid-flight.", category: "Import", type: .warning)
                    break
                }
                
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                var fileName = url.lastPathComponent
                var destURL = documentsDir.appendingPathComponent(fileName)
                let overrideMeta = overrides[url]

                // ── Duplicate Detection ────────────────────────────────────────────────
                let incomingSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let compositeKey = "\(fileName)||\(incomingSize)"

                // 1. Exact match: same filename AND same byte-count in library → true duplicate, skip
                if incomingSize > 0 && (existingKeys.contains(compositeKey) || batchKeys.contains(compositeKey)) {
                    Logger.shared.log("Skipping duplicate: \(fileName) (\(incomingSize) bytes)", category: "Import", type: .info)
                    continue
                }

                // 2. Filename collision — rename to avoid overwriting a different file with the same name
                if existingPaths.contains(fileName) || batchFileNames.contains(fileName) {
                    if let seriesPrefix = overrideMeta?.series, !seriesPrefix.isEmpty {
                        fileName = "\(seriesPrefix) - \(fileName)"
                        destURL = documentsDir.appendingPathComponent(fileName)
                    }
                    // Failsafe UUID suffix for repeated collisions
                    while existingPaths.contains(fileName) || batchFileNames.contains(fileName) || fileManager.fileExists(atPath: destURL.path) {
                        let nameWithoutExt = (fileName as NSString).deletingPathExtension
                        let ext = (fileName as NSString).pathExtension
                        fileName = "\(nameWithoutExt)_\(UUID().uuidString.prefix(6)).\(ext)"
                        destURL = documentsDir.appendingPathComponent(fileName)
                    }
                }

                do {
                    if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }

                    // Aggressive APFS Inode Optimization (Move instead of Copy for Staged Items)
                    if url.path.contains("InksyncStaging_") {
                        try fileManager.moveItem(at: url, to: destURL)
                    } else {
                        try fileManager.copyItem(at: url, to: destURL)
                    }
                    // Re-use incomingSize if known, otherwise fallback to destURL attribute
                    let size = incomingSize > 0 ? incomingSize : ((try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0)

                    let cType = MetadataHeuristics.detectAsymmetricContentType(url: destURL)

                    var smartDisplayName = fileName
                    var smartMetadata = PDFMetadata(title: fileName)

                    // Always calculate the Safe Parent Folder fallback
                    let parentName = url.deletingLastPathComponent().lastPathComponent
                    let invalidParents = ["documents", "inbox", "tmp", "caches", "file provider storage", "downloads", "inksyncstaging_", "folder_spider_", "folderspider_"]
                    var validParentFolder: String? = nil

                    if !invalidParents.contains(where: { parentName.lowercased().hasPrefix($0) }) && parentName.count > 2 && UUID(uuidString: parentName) == nil {
                        validParentFolder = parentName
                    }

                    // ── Single ZIP pass: merge ComicInfo fetch + full parse ─────────────
                    // Previously two separate ZIP opens (fetchNonDestructiveMetadata + ComicInfoParser.parse)
                    // each re-opened the archive; now we do one pass and use both results.
                    let ext = destURL.pathExtension.lowercased()
                    let isArchive = ["cbz", "zip"].contains(ext)
                    
                    var xmlData: (displayName: String, parsedSeries: String?, parsedNumber: String?, parsedVolume: String?, parsedTitle: String?)?
                    var parsedInfo: ComicInfoParser.ComicInfo?
                    let pdfID = UUID()
                    
                    autoreleasepool {
                        xmlData = isArchive ? (try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: destURL)) : nil
                        parsedInfo = isArchive ? ComicInfoParser.parse(from: destURL) : nil
                        
                        if let img = PhysicalFileSystemRouter.extractCoverImageStatic(from: destURL),
                           let jpegData = img.jpegData(compressionQuality: 0.7) {
                            let coversDir = PhysicalFileSystemRouter.getCoversDirectory()
                            let coverURL = coversDir.appendingPathComponent("cover_\(pdfID.uuidString).jpg")
                            try? jpegData.write(to: coverURL)
                        }
                    }

                    if let xmlData = xmlData {
                        smartDisplayName = xmlData.displayName
                        smartMetadata.title = xmlData.parsedTitle ?? overrideMeta?.title ?? smartDisplayName
                        smartMetadata.series = xmlData.parsedSeries ?? overrideMeta?.series ?? validParentFolder
                        smartMetadata.issueNumber = xmlData.parsedNumber
                        smartMetadata.tags.append("Auto XML Scrape")
                        if smartMetadata.issueNumber == nil, let overMeta = overrideMeta {
                            smartMetadata.issueNumber = overMeta.issueNumber
                        }
                    } else if let meta = overrideMeta {
                        smartDisplayName = meta.title
                        smartMetadata = meta
                    } else {
                        smartMetadata.series = validParentFolder
                    }

                    // Apply manga flag and any fields not covered by the XML display layer
                    if let parsedInfo = parsedInfo {
                        smartMetadata.isManga = parsedInfo.manga
                        // Only backfill fields that xmlData didn't already populate
                        if xmlData == nil {
                            smartMetadata.writer    = parsedInfo.writer
                            smartMetadata.publisher = parsedInfo.publisher
                            smartMetadata.summary   = parsedInfo.summary
                            if let year = parsedInfo.year {
                                var comps = DateComponents()
                                comps.year = year; comps.month = 1; comps.day = 1
                                smartMetadata.publicationDate = Calendar.current.date(from: comps)
                            }
                            for tag in parsedInfo.tags {
                                if !smartMetadata.tags.contains(tag) { smartMetadata.tags.append(tag) }
                            }
                        }
                    }

                    var pdf = ConvertedPDF(
                        id: pdfID,
                        name: smartDisplayName,
                        url: destURL,
                        pageCount: 0,
                        fileSize: size,
                        metadata: smartMetadata,
                        contentType: cType
                    )
                    if pdf.contentType == .hybrid || pdf.contentType == .book {
                        pdf.documentSubtype = await self.detectDocumentSubtype(url: destURL, fileSize: size)
                    }
                    // When the vault is unlocked the user has opted-in to their privacy vault;
                    // any files imported in that state are automatically added to it.
                    // When the vault is locked, files are imported as regular (public) library items.
                    pdf.isPrivate = isVaultUnlocked
                    pdf.contentHash = nil // Deferred to prevent UI freeze

                    // Register in O(1) dedup sets
                    batchKeys.insert("\(fileName)||\(size)")
                    batchFileNames.insert(fileName)

                    newPDFs.append(pdf)
                    unstoredPDFs.append(pdf)

                    // Chunk commit every 150 files — updates live library UI without thrashing JSON save.
                    // saveLibrary() is intentionally NOT called here; the single save at the end is enough.
                    if unstoredPDFs.count >= 150 {
                        let chunk = unstoredPDFs
                        unstoredPDFs.removeAll()
                        await MainActor.run {
                            // Build a snapshot set once for O(1) per-item lookup
                            let existing = Set(manager.convertedPDFs.map { $0.url.lastPathComponent })
                            for chunkPdf in chunk where !existing.contains(chunkPdf.url.lastPathComponent) {
                                manager.convertedPDFs.append(chunkPdf)
                            }
                            // Intentionally no saveLibrary() here — avoids 10× expensive JSON serializations
                        }
                    }

                    await ImportMonitorManager.shared.incrementSuccess()
                } catch {
                    Logger.shared.log("importFilesAsSeries: Failed to copy \(fileName): \(error.localizedDescription)", category: "Import", type: .error)
                    await ImportMonitorManager.shared.incrementFailure()
                }
            }

            // Commit remaining files and trigger the SINGLE end-of-import save
            if !unstoredPDFs.isEmpty {
                let chunk = unstoredPDFs
                await MainActor.run {
                    let existing = Set(manager.convertedPDFs.map { $0.url.lastPathComponent })
                    for chunkPdf in chunk where !existing.contains(chunkPdf.url.lastPathComponent) {
                        manager.convertedPDFs.append(chunkPdf)
                    }
                }
            }
            // Single authoritative save for the entire import batch
            await MainActor.run { manager.saveLibrary() }

            return newPDFs
        }.value
        
        await MainActor.run { ImportMonitorManager.shared.completeImport() }
        guard !importedPDFs.isEmpty else { return [] }

        // Fast-path SwiftData insert for ONLY the new records.
        // This bypasses the expensive full-library reconciliation that syncToSwiftData does.
        // The regular saveLibrary debounce will run syncToSwiftData later for full consistency.
        await MigrationService.shared.batchInsertToSwiftData(newPDFs: importedPDFs)

        // ✅ Import History: log each successfully imported file
        for pdf in importedPDFs {
            let size = pdf.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file) : "unknown size"
            Logger.shared.log("✓ Imported: \(pdf.name) (\(size))", category: "Import", type: .success)
        }
        Logger.shared.log("✅ Import batch complete: \(importedPDFs.count) file(s) added to library.", category: "Import", type: .success)
        
        var clusters: [String: [ConvertedPDF]] = [:]
        
        for pdf in importedPDFs {
            let seriesName = (pdf.metadata.series?.isEmpty == false) ? pdf.metadata.series! : "Ungrouped"
            clusters[seriesName, default: []].append(pdf)
        }
        
        let finalClusters = clusters
        let finalImportedPDFs = await MainActor.run {
            var allImported: [ConvertedPDF] = []
            
            for (series, var clusterPDFs) in finalClusters {
                if clusterPDFs.count > 1 && series != "Ungrouped" {
                    let targetCollection: PDFCollection
                    if let existing = manager.collections.first(where: { $0.name == series }), !series.isEmpty {
                        targetCollection = existing
                    } else {
                        let newCol = PDFCollection(id: UUID(), name: series, icon: "books.vertical", color: "orange", creationDate: Date())
                        manager.collections.append(newCol)
                        targetCollection = newCol
                    }
                    
                    for i in 0..<clusterPDFs.count {
                        clusterPDFs[i].collectionId = targetCollection.id
                        clusterPDFs[i].metadata.series = series
                    }
                }
                allImported.append(contentsOf: clusterPDFs)
            }
            
            if !allImported.isEmpty {
                let incomingNames = Set(allImported.map { $0.url.lastPathComponent })
                manager.convertedPDFs.removeAll(where: { incomingNames.contains($0.url.lastPathComponent) })
                manager.convertedPDFs.append(contentsOf: allImported)
            }
            
            manager.saveLibrary()
            return allImported
        }
        return finalImportedPDFs
    }
    
    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String, manager: ConversionManager) async {
        await MainActor.run {
            let targetCollection: PDFCollection
            if let existing = manager.collections.first(where: { $0.name == seriesName }), !seriesName.isEmpty {
                targetCollection = existing
            } else if !seriesName.isEmpty {
                let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "books.vertical", color: "orange", creationDate: Date())
                manager.collections.append(newCol)
                targetCollection = newCol
            } else {
                for pdf in pdfs {
                    manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                    manager.convertedPDFs.append(pdf)
                }
                manager.saveLibrary() // single save for the ungrouped branch
                return
            }

            for var pdf in pdfs {
                pdf.collectionId = targetCollection.id
                pdf.metadata.series = seriesName
                manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == pdf.url.lastPathComponent })
                manager.convertedPDFs.append(pdf)
                // ✅ PERF: saveLibrary() removed from inside loop.
                // The 300ms-debounced save below is called ONCE after all PDFs are appended.
            }
            manager.saveLibrary() // single debounced write for the entire series
        }
    }
    
    nonisolated func assignToSeries(_ pdf: ConvertedPDF, seriesName: String, manager: ConversionManager) {
        Task { @MainActor in
            let targetCollection: PDFCollection
            if let existing = manager.collections.first(where: { $0.name == seriesName }) {
                targetCollection = existing
            } else {
                let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "books.vertical", color: "orange", creationDate: Date())
                manager.collections.append(newCol)
                targetCollection = newCol
            }
            
            if let index = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[index].collectionId = targetCollection.id
                manager.convertedPDFs[index].metadata.series = seriesName
            }
            manager.saveLibrary()
        }
    }
    
    func syncWatchedFolders(manager: ConversionManager) async {
        let localFolders = await MainActor.run { AppSettingsManager.shared.watchedFolders }
        guard !localFolders.isEmpty else { return }
        
        await MainActor.run { manager.isConverting = true; manager.processingStatus = "Background Folder Sync..." }
        defer { Task { await MainActor.run { manager.isConverting = false; manager.processingStatus = "" } } }
        
        let existingPaths = await MainActor.run { Set(manager.convertedPDFs.map { $0.url.lastPathComponent }) }
        
        let newPDFs: [ConvertedPDF] = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            let fileManager = FileManager.default
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            var newlyImported: [ConvertedPDF] = []
            var staleBookmarkIndices: [Int] = []
            
            for (index, folder) in localFolders.enumerated() {
                var isStale = false
                do {
                    await MainActor.run { manager.processingStatus = "Resolving \(folder.name)..." }
                    let resolvedURL = try URL(resolvingBookmarkData: folder.bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    
                    if isStale {
                        staleBookmarkIndices.append(index)
                        continue
                    }
                    
                    let accessing = resolvedURL.startAccessingSecurityScopedResource()
                    defer { if accessing { resolvedURL.stopAccessingSecurityScopedResource() } }
                    
                    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                    guard let enumerator = fileManager.enumerator(at: resolvedURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
                    
                    var fileCount = 0
                    var syncedFileNames = Set<String>() // O(1) per-file dedup within this folder scan
                    while let fileURL = enumerator.nextObject() as? URL {
                        fileCount += 1
                        if fileCount % 50 == 0 {
                            let currentCount = fileCount
                            await MainActor.run { manager.processingStatus = "Scanning \(folder.name) (\(currentCount) items)..." }
                            await Task.yield()
                        }
                        
                        if await ImportMonitorManager.shared.isCancelled {
                            Logger.shared.log("Sync cancelled by user mid-flight.", category: "Import", type: .warning)
                            break
                        }
                        
                        guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                              let isDirectory = resourceValues.isDirectory, !isDirectory else { continue }
                        
                        let ext = fileURL.pathExtension.lowercased()
                        guard ["cbz", "zip", "epub"].contains(ext) else { continue }
                        
                        let fileName = fileURL.lastPathComponent
                        let destURL = documentsDir.appendingPathComponent(fileName)
                        
                    // O(1) dedup — Set built per-folder, updated per file
                    if existingPaths.contains(fileName) || syncedFileNames.contains(fileName) { continue }
                        do {
                            await MainActor.run { manager.processingStatus = "Syncing \(fileName)..." }
                            if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                            try fileManager.copyItem(at: fileURL, to: destURL)

                            // FIX: read size from enumerator resource values — saves one attributesOfItem syscall per file
                            let size = resourceValues.fileSize.map(Int64.init) ?? 0

                            // FIX: restored missing declaration (compile error introduced by previous edit)
                            var smartDisplayName = fileName

                            let isArchive = ["cbz", "zip"].contains(ext)

                            // PERF H1: Single ZIP pass — previously two separate opens:
                            // 1. fetchNonDestructiveMetadata  2. ComicInfoParser.parse
                            // Now we open the archive once and feed both result objects.
                            let xmlData    = isArchive ? (try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: destURL)) : nil
                            let parsedInfo = isArchive ? ComicInfoParser.parse(from: destURL) : nil

                            if let xmlData = xmlData { smartDisplayName = xmlData.displayName }

                            let seriesName = fileURL.deletingLastPathComponent().lastPathComponent
                            var metadata = PDFMetadata(title: smartDisplayName)
                            metadata.series = seriesName

                            // Apply XML display layer first, then backfill with parsedInfo where xmlData left gaps
                            if let xmlData = xmlData {
                                metadata.title = xmlData.parsedTitle ?? smartDisplayName
                                metadata.series = xmlData.parsedSeries ?? seriesName
                                metadata.issueNumber = xmlData.parsedNumber
                                metadata.tags.append("Auto XML Folder Scrape")
                            }
                            if let parsedInfo = parsedInfo {
                                metadata.isManga = parsedInfo.manga
                                if xmlData == nil {
                                    metadata.title = parsedInfo.title ?? smartDisplayName
                                    metadata.series = parsedInfo.series ?? seriesName
                                    metadata.issueNumber = parsedInfo.number
                                    metadata.writer = parsedInfo.writer
                                    metadata.publisher = parsedInfo.publisher
                                    metadata.summary = parsedInfo.summary
                                    if let year = parsedInfo.year {
                                        var comps = DateComponents()
                                        comps.year = year; comps.month = 1; comps.day = 1
                                        metadata.publicationDate = Calendar.current.date(from: comps)
                                    }
                                    for tag in parsedInfo.tags {
                                        if !metadata.tags.contains(tag) { metadata.tags.append(tag) }
                                    }
                                }
                            }
                            
                            let cType = MetadataHeuristics.detectAsymmetricContentType(url: destURL)
                            
                            let pdfID = UUID()
                            if let img = PhysicalFileSystemRouter.extractCoverImageStatic(from: destURL),
                               let jpegData = img.jpegData(compressionQuality: 0.7) {
                                let coversDir = PhysicalFileSystemRouter.getCoversDirectory()
                                let coverURL = coversDir.appendingPathComponent("cover_\(pdfID.uuidString).jpg")
                                try? jpegData.write(to: coverURL)
                            }

                            var pdf = ConvertedPDF(
                                id: pdfID,
                                name: smartDisplayName,
                                url: destURL,
                                pageCount: 0,
                                fileSize: size,
                                metadata: metadata,
                                contentType: cType
                            )
                            if pdf.contentType == .hybrid || pdf.contentType == .book {
                                pdf.documentSubtype = await self.detectDocumentSubtype(url: destURL, fileSize: size)
                            }
                            newlyImported.append(pdf)
                            syncedFileNames.insert(fileName) // track within this scan pass
                        } catch {
                            Logger.shared.log("Failed to sync \(fileName): \(error.localizedDescription)", category: "Import", type: .error)
                        }
                    }
                } catch {
                    Logger.shared.log("Could not resolve bookmark for \(folder.name): \(error.localizedDescription)", category: "Import")
                }
            }
            
            if !staleBookmarkIndices.isEmpty {
                let finalStale = staleBookmarkIndices
                await MainActor.run {
                    for i in finalStale.sorted(by: >) { AppSettingsManager.shared.watchedFolders.remove(at: i) }
                    AppSettingsManager.shared.save()
                }
            }
            return newlyImported
        }.value
        
        if newPDFs.isEmpty { return }
        // ✅ Import History: log linked-library sync batch
        for pdf in newPDFs {
            let size = pdf.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file) : "unknown size"
            Logger.shared.log("✓ Synced from linked folder: \(pdf.name) (\(size))", category: "Import", type: .success)
        }
        Logger.shared.log("✅ Linked library sync: \(newPDFs.count) file(s) added.", category: "Import", type: .success)
        await MainActor.run {
            for var newPdf in newPDFs {
                if let seriesName = newPdf.metadata.series, !seriesName.isEmpty {
                    if let existingCol = manager.collections.first(where: { $0.name == seriesName }) {
                        newPdf.collectionId = existingCol.id
                    } else {
                        let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "folder", color: "blue", creationDate: Date())
                        manager.collections.append(newCol)
                        newPdf.collectionId = newCol.id
                    }
                }
                manager.convertedPDFs.removeAll(where: { $0.url.lastPathComponent == newPdf.url.lastPathComponent })
                manager.convertedPDFs.append(newPdf)
            }
            manager.saveLibrary()
        }

    }
    
    nonisolated func detectContentType(from url: URL, mangaMode: Bool) -> ContentType {
        let ext = url.pathExtension.lowercased()
        let filename = url.deletingPathExtension().lastPathComponent.lowercased()
        
        let mangaKeywords = ["manga", "tankobon", "volume", "chapter", "inuyasha", "shonen", "shoujo", "seinen", "josei"]
        if mangaKeywords.contains(where: { filename.contains($0) }) { return .manga }
        
        switch ext {
        case "cbz", "zip": return mangaMode ? .manga : .comic
        case "pdf":
            let importer = PDFImporter()
            return importer.hasTextContent(url: url) ? .book : .hybrid
        case "epub":
            do {
                guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else { return .book }
                if let containerEntry = archive["META-INF/container.xml"] {
                    var containerData = Data()
                    _ = try archive.extract(containerEntry) { data in containerData.append(data) }
                    
                    if let containerStr = String(data: containerData, encoding: .utf8),
                       let opfPath = containerStr.components(separatedBy: "full-path=\"").last?.components(separatedBy: "\"").first,
                       let opfEntry = archive[opfPath] {
                        
                        var opfData = Data()
                        _ = try archive.extract(opfEntry) { data in opfData.append(data) }
                        
                        if let opfStr = String(data: opfData, encoding: .utf8) {
                            let lowerOPF = opfStr.lowercased()
                            if lowerOPF.contains("pre-paginated") || lowerOPF.contains("comic-book") || lowerOPF.contains("manga") {
                                return .hybrid
                            }
                        }
                    }
                }
            } catch { return .book }
            return .book
        default: return .hybrid
        }
    }
    
    func importPDF(url: URL, manager: ConversionManager) async {
        let fileName = url.deletingPathExtension().lastPathComponent
        await MainActor.run { manager.processingStatus = "Importing \(fileName)..." }
        
        do {
            let tempPDFURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            try FileManager.default.copyItem(at: url, to: tempPDFURL)
            defer { try? FileManager.default.removeItem(at: tempPDFURL) }
            
            let importer = PDFImporter()
            let settings = await AppSettingsManager.shared.conversionSettings
            
            let (extractedCount, newCoverData) = try await Task.detached(priority: .userInitiated) { () -> (Int, Data?) in
                let pageCount = importer.getPageCount(url: tempPDFURL)
                guard pageCount > 0 else { throw PDFImporter.ImportError.emptyPDF }
                
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                
                let maxConcurrent = 4 
                
                return try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
                    var processedCount = 0
                    var firstPageData: Data? = nil
                    
                    for index in 0..<pageCount {
                        if index >= maxConcurrent {
                           if let result = try await group.next() {
                               if result.0 == 0 { firstPageData = result.1 }
                               processedCount += 1
                               
                               let currentCount = processedCount
                               let progress = Double(currentCount) / Double(pageCount)
                               await MainActor.run {
                                   manager.processingStatus = "Importing Page \(currentCount) of \(pageCount)"
                                   manager.conversionProgress = progress
                               }
                           }
                        }
                        
                        group.addTask {
                             try autoreleasepool {
                                let image = try importer.extractPage(url: tempPDFURL, pageIndex: index, dpi: 300)
                                let imageName = String(format: "page_%04d.jpg", index + 1)
                                let imageURL = tempDir.appendingPathComponent(imageName)
                                
                                if let data = image.jpegData(compressionQuality: settings.compressionQuality.value) {
                                    try data.write(to: imageURL)
                                    return (index, index == 0 ? data : nil)
                                }
                                return (index, nil)
                             }
                        }
                    }
                    
                    for try await result in group {
                        if result.0 == 0 { firstPageData = result.1 }
                        processedCount += 1
                        let currentCount = processedCount
                        let progress = Double(currentCount) / Double(pageCount)
                        await MainActor.run {
                            manager.processingStatus = "Importing Page \(currentCount) of \(pageCount)"
                            manager.conversionProgress = progress
                        }
                    }
                    
                    let cbzName = fileName + ".cbz"
                    let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                    let cbzURL = docDir.appendingPathComponent(cbzName)
                    
                    if FileManager.default.fileExists(atPath: cbzURL.path) {
                        try FileManager.default.removeItem(at: cbzURL)
                    }
                    try await ZipUtilities.zipDirectory(tempDir, to: cbzURL)
                    
                    return (pageCount, firstPageData)
                }
            }.value
            
            let mangaMode = await AppSettingsManager.shared.conversionSettings.mangaMode
            let contentType = detectContentType(from: url, mangaMode: mangaMode)
            
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let cbzName = fileName + ".cbz"
            let cbzURL = docDir.appendingPathComponent(cbzName)
            let attributes = try FileManager.default.attributesOfItem(atPath: cbzURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            var newPDF = ConvertedPDF(
                id: UUID(), name: fileName, url: cbzURL,
                pageCount: extractedCount, fileSize: fileSize,
                metadata: PDFMetadata(title: fileName), contentType: contentType
            )
            if newPDF.contentType == ContentType.hybrid || newPDF.contentType == ContentType.book {
                newPDF.documentSubtype = self.detectDocumentSubtype(url: cbzURL, fileSize: fileSize)
            }
            
            if let coverData = newCoverData {
                await manager.saveCoverImage(coverData, for: newPDF)
            }
            
            let finalPDF = newPDF
            await MainActor.run {
                manager.convertedPDFs.append(finalPDF)
                manager.saveLibrary()
                manager.processingStatus = ""
            }
            
        } catch {
            await MainActor.run {
                manager.processingStatus = "PDF import failed: \(error.localizedDescription)"
                manager.appAlert = AppAlert(title: "Import Failed", message: "Could not import PDF: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { manager.processingStatus = "" }
        }
    }
}


