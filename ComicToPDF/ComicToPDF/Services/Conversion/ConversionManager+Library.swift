import SwiftUI
import PDFKit

extension ConversionManager {
    // MARK: - Library State & Import Orchestration
    
    func addConvertedPDF(url: URL, pageCount: Int = 0, fileSize: Int64 = 0, duration: TimeInterval = 0) {
         let pdf = ConvertedPDF(name: url.lastPathComponent, url: url, pageCount: pageCount, fileSize: fileSize, metadata: PDFMetadata(title: url.lastPathComponent), collectionId: nil)
         convertedPDFs.append(pdf)
         saveLibrary()
         Task { await self.generateCoverThumbnail(for: pdf) }
     }
     
    // MARK: - Thumbnails & Helpers
    func generateCoverThumbnail(for pdf: ConvertedPDF) async {
        await ThumbnailGenerationQueue.shared.enqueue(pdf, manager: self)
    }
    
    func backfillMissingThumbnails() {
        PhysicalFileSystemRouter.shared.backfillMissingThumbnails(manager: self)
    }
    
    func loadThumbnailAsync(for pdf: ConvertedPDF) async {
        await PhysicalFileSystemRouter.shared.loadThumbnailAsync(for: pdf, manager: self)
    }
    
    func getThumbnail(for pdf: ConvertedPDF) -> UIImage? {
        PhysicalFileSystemRouter.shared.getThumbnail(for: pdf, manager: self)
    }
    
    func processImportedFiles(urls: [URL]) async {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var skippedFiles: [String] = []
        var filesToProcess: [URL] = []

        // Phase 1: Duplicate detection (security scope needed only to read the filename/ext)
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let finalName: String
            if ext == "epub" {
                finalName = (url.lastPathComponent as NSString).deletingPathExtension + ".cbz"
            } else {
                finalName = url.lastPathComponent
            }
            let destURL = documentsDir.appendingPathComponent(finalName)

            if FileManager.default.fileExists(atPath: destURL.path) {
                skippedFiles.append(finalName)
            } else {
                filesToProcess.append(url)
            }
        }

        if !skippedFiles.isEmpty {
            let message = skippedFiles.count == 1
                ? "Skipped duplicate file:\n\(skippedFiles[0])"
                : "Skipped \(skippedFiles.count) duplicate files."
            await MainActor.run { self.appAlert = AppAlert(title: "Duplicates Skipped", message: message) }
        }

        // Phase 2: Format dispatch + staging
        // PDF and EPUB each launch their own async Task (handles security scope internally).
        // Generic archives (CBZ/CBR/ZIP) are staged for parallel copy below — we do NOT open
        // their security scope here because the defer would fire before withTaskGroup runs.
        var copyJobs: [(source: URL, dest: URL)] = []
        for url in filesToProcess {
            let ext = url.pathExtension.lowercased()

            if ext == "pdf" {
                let captured = url
                Task {
                    let accessing = captured.startAccessingSecurityScopedResource()
                    defer { if accessing { captured.stopAccessingSecurityScopedResource() } }
                    do {
                        let _ = try await ConversionEngine.shared.performPDFImport(url: captured, destFolder: documentsDir)
                    } catch {
                        Logger.shared.log("Engine Import Failed: \(error)", category: "Import", type: .error)
                        await MainActor.run { self.appAlert = AppAlert(title: "Import Failed", message: error.localizedDescription) }
                    }
                }
                continue
            }

            if ext == "epub" {
                let captured = url
                let capturedDocsDir = documentsDir
                // Use Task.detached so EPUBImporter.extractImages (which calls
                // FileManager.unzipItem — a blocking synchronous call) runs on the
                // cooperative thread pool rather than the MainActor thread.
                // Task.detached requires an explicit capture list — it does not
                // implicitly capture self or surrounding locals.
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    let accessing = captured.startAccessingSecurityScopedResource()
                    defer { if accessing { captured.stopAccessingSecurityScopedResource() } }
                    let cleanName = (captured.lastPathComponent as NSString).deletingPathExtension
                    let cbzURL = capturedDocsDir.appendingPathComponent(cleanName + ".cbz")
                    let tempExtractDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    // Always clean up temp dir regardless of outcome
                    defer { try? FileManager.default.removeItem(at: tempExtractDir) }
                    do {
                        try FileManager.default.createDirectory(
                            at: tempExtractDir, withIntermediateDirectories: true)
                        _ = try EPUBImporter.extractImages(from: captured, to: tempExtractDir)
                        try await ZipUtilities.zipDirectory(tempExtractDir, to: cbzURL)
                        PhysicalFileSystemRouter.excludeFromBackup(at: cbzURL)
                        // Trigger library scan so the new CBZ appears immediately
                        await MainActor.run {
                            self.scanLibrary()
                            self.appAlert = AppAlert(
                                title: "Import Success",
                                message: "\(cleanName) added to library.")
                        }
                    } catch {
                        Logger.shared.log(
                            "EPUB Import Failed: \(error.localizedDescription)",
                            category: "Import", type: .error)
                        await MainActor.run {
                            self.appAlert = AppAlert(
                                title: "EPUB Import Failed",
                                message: error.localizedDescription)
                        }
                    }
                }
                continue
            }

            // Generic archive (CBZ/CBR/ZIP) — stage for concurrent copy.
            // Security scope is opened INSIDE the task group task below, not here.
            copyJobs.append((source: url, dest: documentsDir.appendingPathComponent(url.lastPathComponent)))
        }

        // Phase 3: Parallel copy — up to 8 concurrent APFS copy streams.
        // Security scope is opened and closed inside each task so the entitlement is held
        // for the full duration of the copy operation and no longer.
        if !copyJobs.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for job in copyJobs {
                    if inFlight >= 8 { await group.next(); inFlight -= 1 }
                    let src = job.source, dst = job.dest
                    group.addTask {
                        let accessing = src.startAccessingSecurityScopedResource()
                        defer { if accessing { src.stopAccessingSecurityScopedResource() } }
                        do {
                            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                            try FileManager.default.copyItem(at: src, to: dst)
                            PhysicalFileSystemRouter.excludeFromBackup(at: dst)
                        } catch {
                            Logger.shared.log("Failed to copy \(src.lastPathComponent): \(error.localizedDescription)", category: "Import", type: .error)
                        }
                    }
                    inFlight += 1
                }
                for await _ in group {}
            }
        }

        scanLibrary()
    }
    
    // MARK: - Orchestrator Façade Connectors
    func importFolderStructure(from folderURL: URL) async {
        await ImportOrchestrator.shared.importFolderStructure(from: folderURL, manager: self)
    }

    func importFilesAsSeries(urls: [URL], overrides: [URL: PDFMetadata] = [:]) async {
        _ = await ImportOrchestrator.shared.importFilesAsSeries(urls: urls, manager: self, overrides: overrides)
    }

    /// Series-aware import overload used by the Smart Import Pipeline.
    /// All parameters have defaults — every existing call site compiles unchanged.
    @discardableResult
    func importFilesAsSeries(
        urls: [URL],
        seriesName: String? = nil,
        addToExisting: Bool = false,
        forceOverwrite: Bool = false
    ) async -> ImportSummary {
        // Build per-file metadata overrides with the detected series name
        var overrides: [URL: PDFMetadata] = [:]
        if let name = seriesName {
            for url in urls {
                var meta = PDFMetadata(title: url.deletingPathExtension().lastPathComponent)
                meta.series = name
                overrides[url] = meta
            }
        }

        // The orchestrator natively tracks and returns only the successfully imported PDFs
        let importedPDFs = await ImportOrchestrator.shared.importFilesAsSeries(
            urls: urls, manager: self, overrides: overrides
        )
        
        let successCount = importedPDFs.count

        // Build failed URL list (files that didn't make it into the library)
        let importedFilenames = Set(importedPDFs.map { $0.url.lastPathComponent })
        let failedURLs = urls.filter { url in
            !importedFilenames.contains(url.lastPathComponent)
        }

        return ImportSummary(
            seriesName: seriesName ?? "Imported",
            successCount: successCount,
            failedURLs: failedURLs
        )
    }

    func finalizeSeriesImport(pdfs: [ConvertedPDF], seriesName: String) async {
        await ImportOrchestrator.shared.finalizeSeriesImport(pdfs: pdfs, seriesName: seriesName, manager: self)
    }

    func assignToSeries(_ pdf: ConvertedPDF, seriesName: String) {
        ImportOrchestrator.shared.assignToSeries(pdf, seriesName: seriesName, manager: self)
    }

    func syncWatchedFolders() async {
        await ImportOrchestrator.shared.syncWatchedFolders(manager: self)
    }

    func detectContentType(from url: URL) -> ContentType {
        return ImportOrchestrator.shared.detectContentType(from: url, mangaMode: AppSettingsManager.shared.conversionSettings.mangaMode)
    }

    func importPDF(url: URL) async {
        await ImportOrchestrator.shared.importPDF(url: url, manager: self)
    }
    
    // MARK: - Data Management & Overrides
    
    func renamePDF(_ pdf: ConvertedPDF, to newName: String) {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName != pdf.name else { return }

        Task {
            do {
                try await safelyRenamePhysicalFile(pdf: pdf, newName: cleanName)
                await MainActor.run {
                    objectWillChange.send()
                }
            } catch {
                Logger.shared.log("renamePDF failed: \(error.localizedDescription)", category: "Library", type: .error)
            }
        }
    }

    
    // Helpers
    // `autoOrganize` and `findDuplicates` are planned features — not yet implemented.
    func autoOrganize() {
        #if DEBUG
        assertionFailure("autoOrganize() is not yet implemented. Remove from any UI until complete.")
        #endif
    }
    func findDuplicates() async -> [DuplicateGroup] {
        #if DEBUG
        assertionFailure("findDuplicates() is not yet implemented. Remove from any UI until complete.")
        #endif
        return []
    }
    func calculateStorageInfo() -> StorageInfo {
        let used = convertedPDFs.reduce(0) { $0 + $1.fileSize }
        // Query the real available disk space instead of hardcoding 10 GB.
        let totalSize = (try? FileManager.default
            .attributesOfFileSystem(forPath: NSHomeDirectory())[.systemSize] as? Int64) ?? 0
        return StorageInfo(used: used, totalSize: totalSize, appUsage: used)
    }
    func createBackupData() -> BackupData { return BackupData(version: "1.0", date: Date(), settings: AppSettingsManager.shared.conversionSettings, collections: collections, presets: AppSettingsManager.shared.conversionPresets) }
    func restoreFromBackup(_ backup: BackupData) { AppSettingsManager.shared.conversionSettings = backup.settings; self.collections = backup.collections; AppSettingsManager.shared.conversionPresets = backup.presets; saveLibrary(); AppSettingsManager.shared.save() }
    func updatePDFMetadata(_ pdf: ConvertedPDF, metadata: PDFMetadata) { if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].metadata = metadata; saveLibrary() } }

    /// Physically renames the underlying .cbz, .epub, or .pdf on the iOS Storage and updates the database pointer.
    func generateRenameFilename(pdf: ConvertedPDF, newSeriesName: String) -> String {
        let cleanSeries = newSeriesName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var volumeBlock = ""
        if let v = pdf.metadata.volume, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            volumeBlock = " - v\(v.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        
        var numberBlock = ""
        let issue = pdf.metadata.issueNumber ?? MetadataHeuristics.extractIssueNumber(from: pdf.name)
        if let numRaw = issue?.trimmingCharacters(in: .whitespacesAndNewlines), !numRaw.isEmpty {
            if let intNum = Int(numRaw) {
                numberBlock = String(format: " - c%03d", intNum)
            } else {
                numberBlock = " - c\(numRaw)"
            }
        }
        
        var titleBlock = ""
        if let title = pdf.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let oldFilenameStem = pdf.url.deletingPathExtension().lastPathComponent
            if title != oldFilenameStem && title != pdf.name && title != (pdf.metadata.series ?? "") {
                titleBlock = " - \(title)"
            }
        }
        
        var candidateName = "\(cleanSeries)\(volumeBlock)\(numberBlock)\(titleBlock)"
        candidateName = candidateName.replacingOccurrences(of: "/", with: "-")
                                     .replacingOccurrences(of: "\\", with: "-")
                                     .replacingOccurrences(of: ":", with: "-")
                                     .replacingOccurrences(of: "*", with: "")
                                     .replacingOccurrences(of: "?", with: "")
                                     .replacingOccurrences(of: "\"", with: "'")
                                     .replacingOccurrences(of: "<", with: "(")
                                     .replacingOccurrences(of: ">", with: ")")
                                     .replacingOccurrences(of: "|", with: "-")
        return candidateName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String) async throws {
        try await PhysicalFileSystemRouter.shared.safelyRenamePhysicalFile(pdf: pdf, newName: newName, manager: self)
    }

    func safelyRenameSeries(issues: [ConvertedPDF], newSeriesName: String) async {
        do {
            try await PhysicalFileSystemRouter.shared.safelyRenameSeries(issues: issues, newSeriesName: newSeriesName, manager: self)
            await MainActor.run {
                objectWillChange.send()
            }
        } catch {
            Logger.shared.log("safelyRenameSeries failed: \(error.localizedDescription)", category: "Library", type: .error)
        }
    }

    func extractSmartPanels(from url: URL) async throws -> [Int: [PanelExtractor.Panel]]? {
        return try await SmartPanelService.shared.extractSmartPanels(from: url)
    }
}
