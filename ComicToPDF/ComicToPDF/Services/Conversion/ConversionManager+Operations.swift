import SwiftUI
import ZIPFoundation

extension ConversionManager {
    // MARK: - AppBackgroundTask & Omnibus Construction
    @MainActor
    func enqueueOmnibus(name: String, sourceFiles: [ConvertedPDF]) {
        let task = AppBackgroundTask(title: "Building Omnibus: \(name)", progress: 0.0)
        activeTasks.append(task)
        
        let pdfPairs = sourceFiles  // pass full objects — avoids fragile URL equality match for cloud files
        let startCover = sourceFiles.first?.coverImageData
        let settings = AppSettingsManager.shared.conversionSettings
        let docRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let saveDir = docRoot.appendingPathComponent("Merged")
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let taskId = task.id
        
        Task {
            // ✅ Linked Library: Resolve all source URLs through BookmarkResolver
            // This handles both local files, linked drive files, and cloud files transparently.
            var resolvedURLs: [URL] = []
            var accessingTokens: [(URL, Bool)] = []  // Track which URLs we opened so we can close them all
            var tempCloudURLs: [URL] = []             // Track cloud temp files for cleanup after merge
            defer {
                for (url, wasAccessing) in accessingTokens where wasAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
                // Clean up any cloud-downloaded temp files
                tempCloudURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            for pdf in pdfPairs {
                switch pdf.sourceMode {
                case .linked(let bm):
                    if let resolved = try? BookmarkResolver.shared.resolve(bm) {
                        let accessing = resolved.startAccessingSecurityScopedResource()
                        accessingTokens.append((resolved, accessing))
                        resolvedURLs.append(resolved)
                    } else {
                        resolvedURLs.append(pdf.url) // fallback
                    }
                case .cloud:
                    // Download cloud file to a temp location for the duration of the merge.
                    do {
                        let localURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
                        tempCloudURLs.append(localURL)
                        resolvedURLs.append(localURL)
                    } catch {
                        Logger.shared.log("enqueueOmnibus: Cloud download failed for '\(pdf.name)': \(error.localizedDescription)", category: "Cloud", type: .error)
                        // Skip this file rather than crashing the whole omnibus
                    }
                default:
                    resolvedURLs.append(pdf.url)
                }
            }
            do {
                let generatedFiles = try await Task.detached(priority: .userInitiated) {
                    try await EPUBMerger().mergeWithSmartSplit(
                        sourceURLs: resolvedURLs,
                        baseOutputName: name,
                        targetDir: saveDir,
                        settings: settings,
                        overrideCoverData: startCover,
                        progressCallback: { @Sendable progress in
                            Task { @MainActor in
                                TaskEngine.shared.updateTaskProgress(id: taskId, progress: progress)
                            }
                        }
                    )
                }.value
                
                for fileURL in generatedFiles {
                    do {
                        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                        let size = attrs[.size] as? Int64 ?? 0
                        
                        let firstPDF = pdfPairs.first
                        var baseMetadata = firstPDF?.metadata ?? PDFMetadata(title: fileURL.deletingPathExtension().lastPathComponent)
                        baseMetadata.title = fileURL.deletingPathExtension().lastPathComponent
                        baseMetadata.issueNumber = nil
                        baseMetadata.volume = nil
                        
                        var newPDF = ConvertedPDF(
                            id: UUID(),
                            name: fileURL.deletingPathExtension().lastPathComponent,
                            url: fileURL,
                            pageCount: 0,
                            fileSize: size,
                            metadata: baseMetadata,
                            contentType: firstPDF?.contentType ?? .book
                        )
                        newPDF.collectionId = firstPDF?.collectionId
                        newPDF.lastOutputFormat = settings.outputFormat
                        newPDF.coverImageData = startCover
                        self.convertedPDFs.append(newPDF)
                    } catch {}
                }
                self.saveLibrary()
                self.activeTasks.removeAll(where: { $0.id == taskId })
                self.appAlert = AppAlert(title: "Omnibus Complete", message: "Successfully created \(generatedFiles.count) volumes for \(name)")
            } catch {
                self.activeTasks.removeAll(where: { $0.id == taskId })
                self.appAlert = AppAlert(title: "Omnibus Failed", message: error.localizedDescription)
            }
        }
    }
    
    // MARK: - Archive Mutation
    func deletePages(from pdf: ConvertedPDF, pageIndices: Set<Int>) async throws {
        try await ArchiveMutatorService.shared.deletePages(from: pdf, pageIndices: pageIndices, manager: self)
    }

    func reorderPages(_ pdf: ConvertedPDF, newOrder: [Int]) async throws -> URL {
        return try await ArchiveMutatorService.shared.reorderPages(pdf, newOrder: newOrder, manager: self)
    }

    func trimPages(from pdf: ConvertedPDF, pageIndices: Set<Int>, trim: (top: Double, bottom: Double, left: Double, right: Double)) async throws {
        try await ArchiveMutatorService.shared.trimPages(from: pdf, pageIndices: pageIndices, trim: trim, manager: self)
    }

    func extractPages(from pdf: ConvertedPDF, pageIndices: [Int], asImages: Bool) async throws -> URL {
        return try await ArchiveMutatorService.shared.extractPages(from: pdf, pageIndices: pageIndices, asImages: asImages, manager: self)
    }

    func extractPages(from pdf: ConvertedPDF, pageIndices: Range<Int>, asImages: Bool) async throws -> URL {
        return try await extractPages(from: pdf, pageIndices: Array(pageIndices), asImages: asImages)
    }

    // MARK: - Cover Variants
    func extractCoverVariant(from pdf: ConvertedPDF, pageIndex: Int) async throws {
        try await ArchiveMutatorService.shared.extractCoverVariant(from: pdf, pageIndex: pageIndex, manager: self)
    }

    func setActiveCoverVariant(_ variantID: UUID?, for pdf: ConvertedPDF) async {
        await MainActor.run {
            if let idx = self.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                self.convertedPDFs[idx].metadata.selectedCoverID = variantID
                // ✅ PERF: Keyed by UUID (not URL path) — prevents stale orphans after rename
                self.thumbnailCache.removeObject(forKey: pdf.id.uuidString as NSString)
                self.saveLibrary()
                self.objectWillChange.send()  // intentional: selectedCoverID change must redraw
            }
        }
        await generateCoverThumbnail(for: self.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf)
    }

    // MARK: - Chapter Detection
    func detectChapters(for pdf: ConvertedPDF) async {
        guard pdf.contentType == .book || pdf.contentType == .hybrid else { return }
        
        isConverting = true; processingStatus = "Scanning Chapters..."; statusMessage = "0%"
        defer { isConverting = false; statusMessage = nil; processingStatus = "" }
        
        do {
            let chapters = try await ChapterDetector.shared.detectChapters(in: pdf, languages: ["en-US"]) { progress in
                Task { @MainActor in
                    self.statusMessage = String(format: "%.0f%%", progress * 100)
                }
            }
            
            await MainActor.run {
                if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    convertedPDFs[idx].chapters = chapters
                    saveLibrary()
                }
                processingStatus = "Found \(chapters.count) chapters!"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
        } catch {
             Logger.shared.log("Chapter detection failed: \(error)", category: "Editor", type: .error)
             await MainActor.run {
                 processingStatus = "Scan Failed"
             }
        }
    }

    // MARK: - Merge & Convert
    func mergePDFs(_ pdfs: [ConvertedPDF], outputName: String, mangaMode: Bool) async {
        isConverting = true; processingStatus = "Merging..."; statusMessage = "Starting merge..."
        let docRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let docDir = docRoot.appendingPathComponent("Merged")
        try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        let safeName = outputName.isEmpty ? "Merged Collection" : outputName; let outputURL = docDir.appendingPathComponent("\(safeName).epub")
        let merger = EPUBMerger()
        
        // ✅ Linked Library: resolve any linked source files before merging
        var sourceURLs: [URL] = []
        // ✅ FIX: Collect (url, accessingToken) pairs so the access scope stays live
        // for the ENTIRE duration of the detached merge task, not just URL resolution.
        var accessingTokens: [(URL, Bool)] = []
        var tempCloudURLs: [URL] = []  // Cloud temp files — cleaned up after merge
        for pdf in pdfs {
            switch pdf.sourceMode {
            case .linked(let bm):
                if let resolved = try? BookmarkResolver.shared.resolve(bm) {
                    let accessing = resolved.startAccessingSecurityScopedResource()
                    accessingTokens.append((resolved, accessing))
                    sourceURLs.append(resolved)
                } else {
                    sourceURLs.append(pdf.url) // fallback
                }
            case .cloud:
                // Download cloud file to temp for merge. Cleaned up in defer below.
                do {
                    let localURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
                    tempCloudURLs.append(localURL)
                    sourceURLs.append(localURL)
                } catch {
                    Logger.shared.log("mergePDFs: Cloud download failed for '\(pdf.name)': \(error.localizedDescription)", category: "Cloud", type: .error)
                    // Skip rather than aborting the whole merge
                }
            default:
                sourceURLs.append(pdf.url)
            }
        }
        
        var inheritedCover: UIImage?
        if let firstPDF = pdfs.first { inheritedCover = getThumbnail(for: firstPDF) }
        do {
            var mergeSettings = ConversionSettings()
            mergeSettings.mangaMode = mangaMode
            try await Task.detached { try await merger.mergeEPUBs(sourceURLs: sourceURLs, outputURL: outputURL, settings: mergeSettings) }.value
            // ✅ FIX: Release all security-scoped access tokens after the merge is fully complete.
            for (url, wasAccessing) in accessingTokens where wasAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            // ✅ Clean up any cloud temp files after merge succeeds
            tempCloudURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            
            let totalPages = pdfs.reduce(0) { $0 + $1.pageCount }
            
            let firstPDF = pdfs.first
            var baseMetadata = firstPDF?.metadata ?? PDFMetadata(title: safeName)
            baseMetadata.title = safeName
            baseMetadata.issueNumber = nil
            baseMetadata.volume = nil
            
            var newPDF = ConvertedPDF(
                id: UUID(),
                name: outputURL.lastPathComponent,
                url: outputURL,
                pageCount: totalPages,
                fileSize: fileSize,
                metadata: baseMetadata,
                contentType: firstPDF?.contentType ?? .book
            )
            newPDF.collectionId = firstPDF?.collectionId
            await MainActor.run {
                self.convertedPDFs.append(newPDF)
                self.saveLibrary()
            }
            if let cover = inheritedCover {
                thumbnailCache.setObject(cover, forKey: newPDF.id.uuidString as NSString)
                objectWillChange.send()
            } else { Task { await self.generateCoverThumbnail(for: newPDF) } }
            isConverting = false; statusMessage = "✅ Merge Complete!"; scanLibrary()
            Logger.shared.log("Merge Successful: \(outputName)", category: "Converter")
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch {
            // Release tokens on failure path too
            for (url, wasAccessing) in accessingTokens where wasAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            // Clean up cloud temps on failure path too
            tempCloudURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            Logger.shared.log("Merge Failed: \(error)", category: "Converter", type: .error)
            isConverting = false; statusMessage = "Merge Error: \(error.localizedDescription)"
        }
    }
    
    func convertComic(_ pdf: ConvertedPDF, mangaMode: Bool? = nil) async {
        if case .cloud = pdf.sourceMode {
            await MainActor.run {
                self.processingStatus = "Queuing Cloud Download..."
                self.statusMessage = "Downloading for Conversion"
            }
            // downloadAndStore streams the file, saves it to vault, flips sourceMode → .local,
            // then fires ConversionOrchestrator.convertComic automatically.
            await CloudDownloadManager.shared.downloadAndStore(
                pdf: pdf,
                thenConvert: true,
                manager: self,
                mangaMode: mangaMode
            )
            return
        }
        await ConversionOrchestrator.shared.convertComic(pdf, mangaMode: mangaMode, manager: self)
    }
    
    func convertQueue(_ pdfs: [ConvertedPDF]) async {
        let cloudFiles = pdfs.filter { if case .cloud = $0.sourceMode { return true } else { return false } }
        let localFiles = pdfs.filter { if case .cloud = $0.sourceMode { return false } else { return true } }

        // Download each cloud file to vault, then convert sequentially
        for pdf in cloudFiles {
            await CloudDownloadManager.shared.downloadAndStore(
                pdf: pdf,
                thenConvert: true,
                manager: self,
                mangaMode: nil
            )
        }

        if !localFiles.isEmpty {
            await ConversionOrchestrator.shared.convertQueue(localFiles, manager: self)
        }
    }
    
    @discardableResult
    func convertAndMerge(sourceFiles: [ConvertedPDF], outputName: String, mangaMode: Bool, overrideSeries: String? = nil) async -> [ConvertedPDF] {
        // Cloud files: download the first cloud file to vault, then re-run convertAndMerge
        // once it's local. A full multi-file parallel download would need queue state.
        if let firstCloud = sourceFiles.first(where: { if case .cloud = $0.sourceMode { return true } else { return false } }) {
            await MainActor.run {
                self.processingStatus = "Downloading for Merge…"
                self.statusMessage = "Downloading for Merge"
            }
            await CloudDownloadManager.shared.downloadAndStore(
                pdf: firstCloud,
                thenConvert: false,
                manager: self
            )
            // After download completes, firstCloud's sourceMode is .local — retry the merge
            return await ConversionOrchestrator.shared.convertAndMerge(
                sourceFiles: sourceFiles,
                outputName: outputName,
                mangaMode: mangaMode,
                overrideSeries: overrideSeries,
                manager: self
            )
        }
        return await ConversionOrchestrator.shared.convertAndMerge(sourceFiles: sourceFiles, outputName: outputName, mangaMode: mangaMode, overrideSeries: overrideSeries, manager: self)
    }

    // MARK: - Stable Extraction
    func extractImageFiles(from url: URL) async throws -> (workingDir: URL, files: [URL]) {
        return try await EditorSessionManager.shared.extractImageFiles(from: url)
    }
    
    func extractImageURLs(from url: URL) async throws -> [URL] {
        return try await EditorSessionManager.shared.extractImageURLs(from: url)
    }
    
    func extractFullPage(from pdf: ConvertedPDF, index: Int) async throws -> UIImage? {
        return try await EditorSessionManager.shared.extractFullPage(pdfID: pdf.id, pdfURL: pdf.url, index: index)
    }
    
    func endSession() {
        Task {
            await EditorSessionManager.shared.endSession(manager: self)
        }
    }
    
    nonisolated static func loadDownsampledImageStatic(at url: URL, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [ kCGImageSourceShouldCache: false ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
