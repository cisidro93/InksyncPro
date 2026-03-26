import Foundation
import SwiftUI

final class ConversionOrchestrator {
    static let shared = ConversionOrchestrator()
    private init() {}
    
    func convertComic(_ pdf: ConvertedPDF, mangaMode: Bool? = nil, manager: ConversionManager) async {
        await MainActor.run {
            manager.isConverting = true; manager.conversionProgress = 0.0; manager.processingStatus = "Converting..."; manager.statusMessage = "Starting..."
        }
        let isMangaMode = await MainActor.run { mangaMode ?? pdf.metadata.isManga ?? manager.conversionSettings.mangaMode }
        var jobSettings = await MainActor.run { manager.conversionSettings }
        jobSettings.mangaMode = isMangaMode
        
        if pdf.contentType == .book {
            jobSettings.mangaMode = false
            jobSettings.enablePanelSplit = false
            jobSettings.outputPipeline = .standard
            jobSettings.splitWebtoon = false
        }
        
        if let isWebtoon = pdf.metadata.isWebtoon, isWebtoon {
            jobSettings.splitWebtoon = true
            jobSettings.enablePanelSplit = false
            jobSettings.outputPipeline = .standard
        }
        
        do {
            if jobSettings.outputFormat == .pdf {
                let fileManager = FileManager.default
                let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.pdf"
                let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                let imageURLs = try await manager.extractImageURLs(from: pdf.url)
                try PDFGenerator.generate(from: imageURLs, to: outputURL, mangaMode: jobSettings.mangaMode, chapters: pdf.chapters, settings: jobSettings) { progress in
                    Task { @MainActor in manager.conversionProgress = progress; manager.processingStatus = "Converting \(Int(progress * 100))%" }
                }
                await MainActor.run { manager.isConverting = false; manager.conversionProgress = 1.0; manager.statusMessage = "✅ Conversion Complete!"; manager.scanLibrary() }
                Logger.shared.log("Conversion Successful: \(pdf.name) -> PDF", category: "Converter")
            } else if jobSettings.outputFormat == .cbz {
                let fileManager = FileManager.default
                let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".pdf", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.cbz"
                let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                
                await MainActor.run { manager.processingStatus = "Extracting Images..." }
                let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                let imageURLs = try await manager.extractImageURLs(from: pdf.url)
                for (idx, url) in imageURLs.enumerated() {
                    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                    let dest = tempDir.appendingPathComponent(String(format: "page_%04d.%@", idx, ext))
                    try fileManager.copyItem(at: url, to: dest)
                    let p = Double(idx) / Double(imageURLs.count)
                    await MainActor.run { manager.conversionProgress = p; manager.processingStatus = "Packaging CBZ..." }
                }
                
                if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
                try await ZipUtilities.zipDirectory(tempDir, to: outputURL)
                try fileManager.removeItem(at: tempDir)
                
                await MainActor.run { manager.isConverting = false; manager.conversionProgress = 1.0; manager.statusMessage = "✅ Conversion Complete!"; manager.scanLibrary() }
                Logger.shared.log("Conversion Successful: \(pdf.name) -> CBZ", category: "Converter")
            } else if jobSettings.outputPipeline == .proPanel {
                await MainActor.run { manager.processingStatus = "Loading Panel Data..." }
                let combinedManifest = await manager.getCombinedManifest(for: pdf)
                let pvConverter = PanelViewEPUBConverter()
                let newURLs = try await pvConverter.convert(sourceURL: pdf.url, settings: jobSettings, panels: combinedManifest) { progress in
                    Task { @MainActor in manager.conversionProgress = progress; manager.processingStatus = "Converting \(Int(progress * 100))%" }
                }
                for epubURL in newURLs { try? await manager.injectMetadata(into: epubURL, panels: combinedManifest, metadata: pdf.metadata) }
                await MainActor.run { manager.isConverting = false; manager.conversionProgress = 1.0; manager.statusMessage = "✅ Panel View EPUB Ready!"; manager.scanLibrary() }
                Logger.shared.log("PanelView Conversion Successful: \(pdf.name)", category: "Converter")
            } else {
                let converter = CBZToEPUBConverter()
                let newURLs = try await converter.convert(sourceURL: pdf.url, settings: jobSettings, manualManifest: nil) { progress in
                    Task { @MainActor in manager.conversionProgress = progress; manager.processingStatus = "Converting \(Int(progress * 100))%" }
                }
                for epubURL in newURLs { try? await manager.injectMetadata(into: epubURL, panels: [:], metadata: pdf.metadata) }
                await MainActor.run { manager.isConverting = false; manager.conversionProgress = 1.0; manager.statusMessage = "✅ Conversion Complete!"; manager.scanLibrary() }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { manager.statusMessage = nil }
        } catch {
            Logger.shared.log("Conversion Failed: \(error)", category: "Converter", type: .error)
            await MainActor.run { manager.isConverting = false; manager.statusMessage = "Error: \(error.localizedDescription)" }
        }
    }
    
    func convertQueue(_ pdfs: [ConvertedPDF], manager: ConversionManager) async {
        guard !pdfs.isEmpty else { return }
        await MainActor.run { manager.isConverting = true }
        
        for (index, pdf) in pdfs.enumerated() {
            if Task.isCancelled { break }
            let currentNum = index + 1
            let total = pdfs.count
            
            await MainActor.run { manager.processingStatus = "Converting \(currentNum) of \(total)"; manager.statusMessage = "Processing \(pdf.name)..."; manager.conversionProgress = 0.0 }
            
            var jobSettings = await MainActor.run { manager.conversionSettings }
            if pdf.contentType == .book {
                jobSettings.mangaMode = false; jobSettings.enablePanelSplit = false; jobSettings.outputPipeline = .standard; jobSettings.splitWebtoon = false
            }
            if let isWebtoon = pdf.metadata.isWebtoon, isWebtoon {
                jobSettings.splitWebtoon = true; jobSettings.enablePanelSplit = false; jobSettings.outputPipeline = .standard
            }
            
            do {
                if jobSettings.outputFormat == .pdf {
                    let fileManager = FileManager.default
                    let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.pdf"
                    let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                    let imageURLs = try await manager.extractImageURLs(from: pdf.url)
                    try PDFGenerator.generate(from: imageURLs, to: outputURL, mangaMode: jobSettings.mangaMode, chapters: pdf.chapters, settings: jobSettings) { p in
                        Task { @MainActor in manager.conversionProgress = p; manager.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)" }
                    }
                    await MainActor.run { manager.scanLibrary() }
                } else if jobSettings.outputFormat == .cbz {
                    let fileManager = FileManager.default
                    let pName = pdf.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".pdf", with: "").replacingOccurrences(of: ".zip", with: "") + "_Converted.cbz"
                    let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(pName)
                    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    let imageURLs = try await manager.extractImageURLs(from: pdf.url)
                    for (idx, url) in imageURLs.enumerated() {
                        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                        let dest = tempDir.appendingPathComponent(String(format: "page_%04d.%@", idx, ext))
                        try fileManager.copyItem(at: url, to: dest)
                        let p = Double(idx) / Double(imageURLs.count)
                        await MainActor.run { manager.conversionProgress = p; manager.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)" }
                    }
                    if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
                    try await ZipUtilities.zipDirectory(tempDir, to: outputURL)
                    try fileManager.removeItem(at: tempDir)
                    await MainActor.run { manager.scanLibrary() }
                } else if jobSettings.outputPipeline == .proPanel {
                    await MainActor.run { manager.processingStatus = "Reading panels for \(pdf.name)..." }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let combinedManifest = await manager.getCombinedManifest(for: pdf)
                    let pvConverter = PanelViewEPUBConverter()
                    let newURLs = try await pvConverter.convert(sourceURL: pdf.url, settings: jobSettings, panels: combinedManifest) { p in
                        Task { @MainActor in manager.conversionProgress = p; manager.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)" }
                    }
                    for epubURL in newURLs { try? await manager.injectMetadata(into: epubURL, panels: combinedManifest, metadata: pdf.metadata) }
                    await MainActor.run { manager.scanLibrary() }
                } else {
                    let converter = CBZToEPUBConverter()
                    let newURLs = try await converter.convert(sourceURL: pdf.url, settings: jobSettings, manualManifest: nil) { p in
                        Task { @MainActor in manager.conversionProgress = p; manager.processingStatus = "Converting \(currentNum) of \(total) (\(Int(p * 100))%)" }
                    }
                    for epubURL in newURLs { try? await manager.injectMetadata(into: epubURL, panels: [:], metadata: pdf.metadata) }
                    await MainActor.run { manager.scanLibrary() }
                }
            } catch {
                await MainActor.run { manager.statusMessage = "Error on \(pdf.name)" }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        await MainActor.run { manager.isConverting = false; manager.statusMessage = nil }
    }
    
    @discardableResult
    func convertAndMerge(sourceFiles: [ConvertedPDF], outputName: String, mangaMode: Bool, overrideSeries: String? = nil, manager: ConversionManager) async -> [ConvertedPDF] {
        guard !sourceFiles.isEmpty else { return [] }
        await MainActor.run { manager.isConverting = true }
        var newMergedPDFs: [ConvertedPDF] = []
        
        let fileManager = FileManager.default
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var jobSettings = await MainActor.run { manager.conversionSettings }
        jobSettings.mangaMode = mangaMode
        
        do {
            if jobSettings.outputFormat == .pdf || jobSettings.outputFormat == .cbz {
                var batches: [[(url: URL, chapter: Chapter)]] = []
                var currentBatch: [(url: URL, chapter: Chapter)] = []
                var currentBatchSize: Int64 = 0
                let sizeLimit = jobSettings.splitMode.limit
                var firstCoverImageData: Data? = nil
                
                for (index, file) in sourceFiles.enumerated() {
                    if Task.isCancelled { break }
                    await MainActor.run { manager.processingStatus = "Step 1/2: Extracting \(index + 1) of \(sourceFiles.count)"; manager.statusMessage = "Extracting \(file.name)..."; manager.conversionProgress = Double(index) / Double(sourceFiles.count) }
                    
                    let fileSize = file.fileSize
                    if sizeLimit != Int64.max && !currentBatch.isEmpty && (currentBatchSize + fileSize) > sizeLimit { batches.append(currentBatch); currentBatch = []; currentBatchSize = 0 }
                    
                    var images = try await manager.extractImageURLs(from: file.url)
                    if file.url.pathExtension.lowercased() == "pdf", let isManga = file.metadata.isManga, isManga { images.reverse() }
                    
                    let chapterStartIndex = currentBatch.count
                    let chapterTitle = file.name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".zip", with: "").replacingOccurrences(of: ".pdf", with: "").replacingOccurrences(of: ".epub", with: "")
                    let chapter = Chapter(title: chapterTitle, pageIndex: chapterStartIndex)
                    
                    if firstCoverImageData == nil, let firstImageURL = images.first { firstCoverImageData = try? Data(contentsOf: firstImageURL) }
                    for imageURL in images { currentBatch.append((url: imageURL, chapter: chapter)) }
                    currentBatchSize += fileSize
                }
                
                if !currentBatch.isEmpty { batches.append(currentBatch) }
                guard !batches.isEmpty && !batches[0].isEmpty else { await MainActor.run { manager.isConverting = false }; return newMergedPDFs }
                
                await MainActor.run { manager.processingStatus = "Step 2/2: Merging..."; manager.statusMessage = "Merging \(batches.count) parts..."; manager.conversionProgress = 0.5 }
                let ext = jobSettings.outputFormat == .cbz ? ".cbz" : ".pdf"
                
                for (batchIndex, batch) in batches.enumerated() {
                    let partSuffix = batches.count > 1 ? " (pt \(batchIndex + 1))" : ""
                    let outputFilename = (outputName.isEmpty ? "Merged Collection" : outputName) + partSuffix + ext
                    let finalOutputURL = documentsDir.appendingPathComponent(outputFilename)
                    if fileManager.fileExists(atPath: finalOutputURL.path) { try fileManager.removeItem(at: finalOutputURL) }
                    
                    var batchImages = batch.map { $0.url }
                    var mergedChapters: [Chapter] = []
                    var seenChapters = Set<String>()
                    for item in batch { if !seenChapters.contains(item.chapter.title) { mergedChapters.append(item.chapter); seenChapters.insert(item.chapter.title) } }
                    
                    if let coverData = firstCoverImageData, batches.count > 1 {
                        let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: batches.count)
                        let tempCoverURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                        try? badgedCoverData.write(to: tempCoverURL)
                        if !batchImages.isEmpty { batchImages[0] = tempCoverURL }
                    }
                    
                    if jobSettings.outputFormat == .pdf {
                        let totalBatches = batches.count
                        try await Task.detached {
                            try PDFGenerator.generate(from: batchImages, to: finalOutputURL, mangaMode: jobSettings.mangaMode, chapters: mergedChapters, settings: jobSettings) { progress in
                                let baseProgress = Double(batchIndex) / Double(totalBatches)
                                let currentPartProgress = progress / Double(totalBatches)
                                Task { @MainActor in manager.conversionProgress = 0.5 + (0.5 * (baseProgress + currentPartProgress)) }
                            }
                        }.value
                    } else {
                        try await Task.detached {
                            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                            for (idx, url) in batchImages.enumerated() {
                                let pathExt = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                                let dest = tempDir.appendingPathComponent(String(format: "page_%04d.%@", idx, pathExt))
                                try fileManager.copyItem(at: url, to: dest)
                            }
                            try await ZipUtilities.zipDirectory(tempDir, to: finalOutputURL)
                            try fileManager.removeItem(at: tempDir)
                        }.value
                    }
                    
                    let finalFileSize = (try? finalOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    let outputPDF = ConvertedPDF(name: outputFilename, url: finalOutputURL, pageCount: batch.count, fileSize: finalFileSize, metadata: PDFMetadata(title: outputFilename, series: overrideSeries, isManga: jobSettings.mangaMode))
                    newMergedPDFs.append(outputPDF)
                    await MainActor.run { manager.convertedPDFs.insert(outputPDF, at: 0) }
                }
                
                await MainActor.run { manager.scanLibrary(); manager.statusMessage = "✅ Merge Complete!"; manager.processingStatus = ""; manager.conversionProgress = 1.0; manager.isConverting = false }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { manager.statusMessage = nil }
                return newMergedPDFs
            }
            
            // EPUB Bulk Merge (Existing Pipeline but with limits)
            var generatedBatches: [[URL]] = []
            var currentEPUBBatch: [URL] = []
            var currentEPUBBatchSize: Int64 = 0
            let epubSizeLimit = jobSettings.splitMode.limit
            var firstEPUBFileCoverData: Data? = nil
            
            for (index, file) in sourceFiles.enumerated() {
                if Task.isCancelled { break }
                let currentNum = index + 1
                await MainActor.run { manager.processingStatus = "Step 1/2: Converting \(currentNum) of \(sourceFiles.count)"; manager.statusMessage = "Converting \(file.name)..."; manager.conversionProgress = 0.0 }
                
                let fileSize = file.fileSize
                if epubSizeLimit != Int64.max && !currentEPUBBatch.isEmpty && (currentEPUBBatchSize + fileSize) > epubSizeLimit { generatedBatches.append(currentEPUBBatch); currentEPUBBatch = []; currentEPUBBatchSize = 0 }
                
                if firstEPUBFileCoverData == nil {
                    if var images = try? await manager.extractImageURLs(from: file.url) {
                        if file.url.pathExtension.lowercased() == "pdf" && (file.metadata.isManga == true) { images.reverse() }
                        if let firstImage = images.first { firstEPUBFileCoverData = try? Data(contentsOf: firstImage) }
                    }
                }
                
                await MainActor.run { manager.processingStatus = "Reading Source Panels..." }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let combinedManifest = await manager.getCombinedManifest(for: file)
                let isMangaPDF = file.url.pathExtension.lowercased() == "pdf" && (file.metadata.isManga == true)
                let resultingURLs: [URL]
                
                if jobSettings.outputPipeline == .proPanel {
                    let converter = PanelViewEPUBConverter()
                    resultingURLs = try await converter.convert(sourceURL: file.url, settings: jobSettings, panels: combinedManifest, sourceIsMangaPDF: isMangaPDF) { progress in
                        Task { @MainActor in manager.conversionProgress = progress }
                    }
                } else {
                    let converter = CBZToEPUBConverter()
                    resultingURLs = try await converter.convert(sourceURL: file.url, settings: jobSettings, manualManifest: nil, sourceIsMangaPDF: isMangaPDF) { progress in
                        Task { @MainActor in manager.conversionProgress = progress }
                    }
                }
                
                currentEPUBBatch.append(contentsOf: resultingURLs)
                currentEPUBBatchSize += fileSize
                for epubURL in resultingURLs { try? await manager.injectMetadata(into: epubURL, panels: combinedManifest, metadata: file.metadata) }
            }
            
            if !currentEPUBBatch.isEmpty { generatedBatches.append(currentEPUBBatch) }
            guard !generatedBatches.isEmpty && !generatedBatches[0].isEmpty else { await MainActor.run { manager.isConverting = false }; return newMergedPDFs }
            
            await MainActor.run { manager.processingStatus = "Step 2/2: Merging..."; manager.statusMessage = "Merging \(generatedBatches.count) EPUB parts..."; manager.conversionProgress = 0.5 }
            let merger = EPUBMerger()
            
            for (batchIndex, batch) in generatedBatches.enumerated() {
                let partSuffix = generatedBatches.count > 1 ? " (pt \(batchIndex + 1))" : ""
                let outputFilename = (outputName.isEmpty ? "Merged Collection" : outputName) + partSuffix + ".epub"
                let finalOutputURL = documentsDir.appendingPathComponent(outputFilename)
                
                var overrideCover: Data? = nil
                if let baseCover = firstEPUBFileCoverData, generatedBatches.count > 1 { overrideCover = CoverGenerator.generateCover(from: baseCover, partNumber: batchIndex + 1, totalParts: generatedBatches.count) }
                
                try await merger.mergeEPUBs(sourceURLs: batch, outputURL: finalOutputURL, settings: jobSettings, overrideCoverData: overrideCover)
                
                let finalFileSize = (try? finalOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let totalPages = await Task.detached(priority: .background) { return PhysicalFileSystemRouter.getPageCountStatic(from: finalOutputURL) }.value
                let outputPDF = ConvertedPDF(name: outputFilename, url: finalOutputURL, pageCount: totalPages, fileSize: finalFileSize, metadata: PDFMetadata(title: outputFilename, series: overrideSeries, isManga: mangaMode))
                newMergedPDFs.append(outputPDF)
                await MainActor.run { manager.convertedPDFs.insert(outputPDF, at: 0) }
            }

            await MainActor.run { manager.statusMessage = "Cleaning up..." }
            for batch in generatedBatches { for url in batch { try? fileManager.removeItem(at: url) } }
            
            await MainActor.run { manager.scanLibrary(); manager.statusMessage = "✅ Merge Complete!"; manager.processingStatus = ""; manager.conversionProgress = 1.0; manager.isConverting = false }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { manager.statusMessage = nil }
            return newMergedPDFs
        } catch {
            await MainActor.run { manager.statusMessage = "Merge Failed: \(error.localizedDescription)"; manager.isConverting = false }
            return newMergedPDFs
        }
    }
}
