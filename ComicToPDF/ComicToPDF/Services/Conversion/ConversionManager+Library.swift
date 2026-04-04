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
        await PhysicalFileSystemRouter.shared.generateCoverThumbnail(for: pdf, manager: self)
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
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var skippedFiles: [String] = []
        var filesToProcess: [URL] = []
        
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
            let message = skippedFiles.count == 1 ? "Skipped duplicate file:\n\(skippedFiles[0])" : "Skipped \(skippedFiles.count) duplicate files."
            await MainActor.run {
                self.appAlert = AppAlert(title: "Duplicates Skipped", message: message)
            }
        }
        
        for url in filesToProcess {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let ext = url.pathExtension.lowercased()
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

            if ext == "pdf" {
                Task {
                    do {
                        let _ = try await ConversionEngine.shared.performPDFImport(url: url, destFolder: documentsDir)
                    } catch {
                        Logger.shared.log("Engine Import Failed: \(error)", category: "Import", type: .error)
                        await MainActor.run {
                            self.appAlert = AppAlert(title: "Import Failed", message: error.localizedDescription)
                        }
                    }
                }
                continue
            } else if ext == "epub" {
                 Task {
                     do {
                         let cleanName = (url.lastPathComponent as NSString).deletingPathExtension
                         let cbzName = cleanName + ".cbz"
                         let cbzURL = documentsDir.appendingPathComponent(cbzName)
                         
                         let tempExtractDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                         try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
                         
                         _ = try EPUBImporter.extractImages(from: url, to: tempExtractDir)
                         
                         try await ZipUtilities.zipDirectory(tempExtractDir, to: cbzURL)
                         
                         try? FileManager.default.removeItem(at: tempExtractDir)
                         
                         await MainActor.run {
                             self.scanLibrary()
                             self.appAlert = AppAlert(title: "Import Success", message: "Imported EPUB as Comic.")
                         }
                     } catch {
                         Logger.shared.log("EPUB Import Failed: \(error.localizedDescription)", category: "Import", type: .error)
                         await MainActor.run {
                             self.appAlert = AppAlert(title: "EPUB Import Failed", message: error.localizedDescription)
                         }
                     }
                 }
                 continue
            }
            
            do {
                let fileName = url.lastPathComponent
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let destURL = docDir.appendingPathComponent(fileName)
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch { 
                Logger.shared.log("Failed to copy imported file \(url.lastPathComponent): \(error.localizedDescription)", category: "Import", type: .error)
            }
        }
        scanLibrary()
    }
    
    // MARK: - Orchestrator Façade Connectors
    func importFolderStructure(from folderURL: URL) async {
        await ImportOrchestrator.shared.importFolderStructure(from: folderURL, manager: self)
    }

    func importFilesAsSeries(urls: [URL], overrides: [URL: PDFMetadata] = [:]) async {
        await ImportOrchestrator.shared.importFilesAsSeries(urls: urls, manager: self, overrides: overrides)
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
        
        let fileManager = FileManager.default
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        let newURL = docDir.appendingPathComponent(cleanName)
        
        if fileManager.fileExists(atPath: newURL.path) {
            Logger.shared.log("Rename failed: File exists", category: "Library")
            return
        }
        
        do {
            try fileManager.moveItem(at: pdf.url, to: newURL)
            
            if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                let updatedPDF = ConvertedPDF(
                    id: pdf.id,
                    name: cleanName,
                    url: newURL,
                    pageCount: pdf.pageCount,
                    fileSize: pdf.fileSize,
                    metadata: pdf.metadata,
                    collectionId: pdf.collectionId,
                    isFavorite: pdf.isFavorite,
                    coverImageData: pdf.coverImageData
                )
                convertedPDFs[idx] = updatedPDF
                
                if let image = thumbnailCache.object(forKey: pdf.url.path as NSString) {
                    thumbnailCache.setObject(image, forKey: newURL.path as NSString)
                    thumbnailCache.removeObject(forKey: pdf.url.path as NSString)
                }
                
                saveLibrary()
                objectWillChange.send()
            }
        } catch {
            Logger.shared.log("Rename Error: \(error)", category: "Library")
        }
    }
    
    // Helpers
    func autoOrganize() {}
    func findDuplicates() async -> [DuplicateGroup] { return [] }
    func calculateStorageInfo() -> StorageInfo { let total = convertedPDFs.reduce(0) { $0 + $1.fileSize }; return StorageInfo(used: total, totalSize: 10_000_000_000, appUsage: total) }
    func createBackupData() -> BackupData { return BackupData(version: "1.0", date: Date(), settings: AppSettingsManager.shared.conversionSettings, collections: collections, presets: AppSettingsManager.shared.conversionPresets) }
    func restoreFromBackup(_ backup: BackupData) { AppSettingsManager.shared.conversionSettings = backup.settings; self.collections = backup.collections; AppSettingsManager.shared.conversionPresets = backup.presets; saveLibrary(); AppSettingsManager.shared.save() }
    func updatePDFMetadata(_ pdf: ConvertedPDF, metadata: PDFMetadata) { if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { convertedPDFs[idx].metadata = metadata; saveLibrary() } }

    /// Physically renames the underlying .cbz, .epub, or .pdf on the iOS Storage and updates the database pointer.
    func safelyRenamePhysicalFile(pdf: ConvertedPDF, newName: String) throws {
        try PhysicalFileSystemRouter.shared.safelyRenamePhysicalFile(pdf: pdf, newName: newName, manager: self)
    }

    func extractSmartPanels(from url: URL) async throws -> [Int: [PanelExtractor.Panel]]? {
        return try await SmartPanelService.shared.extractSmartPanels(from: url)
    }
}
