import SwiftUI
import ZIPFoundation

extension ConversionManager {
    // MARK: - AppBackgroundTask & Omnibus Construction
    @MainActor
    func enqueueOmnibus(name: String, sourceFiles: [ConvertedPDF]) {
        let task = AppBackgroundTask(title: "Building Omnibus: \(name)", progress: 0.0)
        activeTasks.append(task)
        
        let urls = sourceFiles.map { $0.url }
        let startCover = sourceFiles.first?.coverImageData
        let settings = AppSettingsManager.shared.conversionSettings
        let saveDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        Task.detached(priority: .userInitiated) {
            do {
                let generatedFiles = try await EPUBMerger().mergeWithSmartSplit(
                    sourceURLs: urls,
                    baseOutputName: name,
                    targetDir: saveDir,
                    settings: settings,
                    overrideCoverData: startCover,
                    progressCallback: { progress in
                        Task { @MainActor in task.progress = progress }
                    }
                )
                
                Task { @MainActor in
                    for fileURL in generatedFiles {
                        do {
                            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                            let size = attrs[.size] as? Int64 ?? 0
                            
                            var newPDF = ConvertedPDF(
                                id: UUID(),
                                name: fileURL.deletingPathExtension().lastPathComponent,
                                url: fileURL,
                                pageCount: 0,
                                fileSize: size,
                                metadata: PDFMetadata(title: fileURL.deletingPathExtension().lastPathComponent),
                                contentType: .book
                            )
                            newPDF.lastOutputFormat = settings.outputFormat
                            newPDF.coverImageData = startCover
                            self.convertedPDFs.append(newPDF)
                        } catch {}
                    }
                    self.saveLibrary()
                    self.activeTasks.removeAll(where: { $0.id == task.id })
                    self.appAlert = AppAlert(title: "Omnibus Complete", message: "Successfully created \(generatedFiles.count) volumes for \(name)")
                }
            } catch {
                Task { @MainActor in
                    self.activeTasks.removeAll(where: { $0.id == task.id })
                    self.appAlert = AppAlert(title: "Omnibus Failed", message: error.localizedDescription)
                }
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
                self.thumbnailCache.removeObject(forKey: pdf.url.path as NSString)
                self.saveLibrary()
                self.objectWillChange.send()
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
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let safeName = outputName.isEmpty ? "Merged Collection" : outputName; let outputURL = docDir.appendingPathComponent("\(safeName).epub")
        let merger = EPUBMerger(); let sourceURLs = pdfs.map { $0.url }
        var inheritedCover: UIImage?
        if let firstPDF = pdfs.first { inheritedCover = getThumbnail(for: firstPDF) }
        do {
            var mergeSettings = ConversionSettings()
            mergeSettings.mangaMode = mangaMode
            try await Task.detached { try await merger.mergeEPUBs(sourceURLs: sourceURLs, outputURL: outputURL, settings: mergeSettings) }.value
            let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            
            let totalPages = pdfs.reduce(0) { $0 + $1.pageCount }
            
            let newPDF = ConvertedPDF(name: outputURL.lastPathComponent, url: outputURL, pageCount: totalPages, fileSize: fileSize, metadata: PDFMetadata(title: safeName))
            await MainActor.run { self.convertedPDFs.append(newPDF) }
            if let cover = inheritedCover { thumbnailCache.setObject(cover, forKey: outputURL.path as NSString); objectWillChange.send() }
            else { Task { await self.generateCoverThumbnail(for: newPDF) } }
            isConverting = false; statusMessage = "✅ Merge Complete!"; scanLibrary()
            Logger.shared.log("Merge Successful: \(outputName)", category: "Converter")
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000); self.statusMessage = nil
        } catch { 
            Logger.shared.log("Merge Failed: \(error)", category: "Converter", type: .error)
            isConverting = false; statusMessage = "Merge Error: \(error.localizedDescription)" 
        }
    }
    
    func convertComic(_ pdf: ConvertedPDF, mangaMode: Bool? = nil) async {
        await ConversionOrchestrator.shared.convertComic(pdf, mangaMode: mangaMode, manager: self)
    }
    
    func convertQueue(_ pdfs: [ConvertedPDF]) async {
        await ConversionOrchestrator.shared.convertQueue(pdfs, manager: self)
    }
    
    @discardableResult
    func convertAndMerge(sourceFiles: [ConvertedPDF], outputName: String, mangaMode: Bool, overrideSeries: String? = nil) async -> [ConvertedPDF] {
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
