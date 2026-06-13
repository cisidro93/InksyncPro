import SwiftUI
import ZIPFoundation
import Foundation
import SwiftData

struct CBZToEPUBConverter: Sendable {
    
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]?, sourceIsMangaPDF: Bool = false, coverOverrideData: Data? = nil, customOutputName: String? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        Logger.shared.log("Starting Enterprise Conversion (No TOC). Manual Manifest: \(manualManifest?.count ?? 0) pages", category: "Converter")
        
        let fileManager = FileManager.default
        
        // Strip ALL extensions
        var baseFilename: String
        if let customName = customOutputName, !customName.isEmpty {
            var derived = customName
            while derived.contains(".") {
                let stripped = (derived as NSString).deletingPathExtension
                if stripped == derived { break }
                derived = stripped
            }
            baseFilename = derived
        } else {
            var derived = sourceURL.lastPathComponent
            while !derived.isEmpty && derived.contains(".") {
                let stripped = (derived as NSString).deletingPathExtension
                if stripped == derived { break } // No more extensions
                derived = stripped
            }
            baseFilename = derived
        }
        
        // Stage 1
        progress(0.1)
        let extractResult = try await extractArchive(from: sourceURL)
        let tempDir = extractResult.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let originalImageURLs = extractResult.imageURLs
        
        let processedSandboxDir = fileManager.temporaryDirectory.appendingPathComponent("ProcessedSandbox_\(UUID().uuidString)")
        try fileManager.createDirectory(at: processedSandboxDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: processedSandboxDir) }
        
        var batches = try await processAndBatch(imageURLs: originalImageURLs, settings: settings, sandboxDir: processedSandboxDir, progress: progress)
        let totalBatches = batches.count
        
        // Stage 3 & 4
        var generatedFiles: [URL] = []
        var globalFirstBatchCoverData: Data? = nil
        
        for batchIndex in 0..<totalBatches {
            // Memory Release trick: Empty the current batch so the disk URLs drop out of scope soon
            let batch = batches[batchIndex]
            batches[batchIndex] = []
            
            let partSuffix = totalBatches > 1 ? " (pt \(batchIndex + 1))" : ""
            let epubName = baseFilename + partSuffix
            
            if let coverOverride = coverOverrideData {
                globalFirstBatchCoverData = coverOverride
            } else if batchIndex == 0, let firstImage = batch.first {
                globalFirstBatchCoverData = try? Data(contentsOf: firstImage.processedDiskURL)
            }
            
            let batchDir = try await buildEPUBDirectory(
                sourceURL: sourceURL,
                batch: batch,
                batchIndex: batchIndex,
                totalBatches: totalBatches,
                baseFilename: epubName,
                settings: settings,
                coverData: globalFirstBatchCoverData,
                isCoverOverrideActive: coverOverrideData != nil
            )
            
            let outputURL = try await packageEPUB(batchDir: batchDir, outputName: epubName)
            generatedFiles.append(outputURL)
            
            progress(0.5 + (0.5 * Double(batchIndex + 1) / Double(totalBatches)))
        }
        
        progress(1.0)
        return generatedFiles
    }
    
    // Stage 1 — Extract archive to temp directory, return sorted image URLs
    private func extractArchive(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        Logger.shared.log("Stage 1 Start: Extracting \(sourceURL.lastPathComponent)", category: "Converter")
        // ZipUtilities.extractComic requires the caller to hold the security scope.
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        guard !extractionResult.imageURLs.isEmpty else {
            throw NSError(domain: "Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        Logger.shared.log("Stage 1 End: Extracted \(extractionResult.imageURLs.count) images", category: "Converter")
        return (workingDir: extractionResult.workingDir, imageURLs: extractionResult.imageURLs)
    }

    // Stage 2 — Process and batch images...
    private func processAndBatch(imageURLs: [URL], settings: ConversionSettings, sandboxDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [[(processedDiskURL: URL, sourceURL: URL, index: Int)]] {
        Logger.shared.log("Stage 2 Start: Processing and Batching", category: "Converter")
        var batches: [[(processedDiskURL: URL, sourceURL: URL, index: Int)]] = []
        var currentBatch: [(processedDiskURL: URL, sourceURL: URL, index: Int)] = []
        var currentBatchSize: Int64 = 0
        let limit = settings.splitMode.limit
        
        let totalCount = Double(imageURLs.count)
        var globalImageIndex = 0
        
        for (originalIndex, srcURL) in imageURLs.enumerated() {
            autoreleasepool {
                // A. Check for Webtoon Slicing
                var imagesToProcess: [UIImage] = []
                var isSliced = false
                
                // Retrieve native dimensions without decompressing the UIImage to save RAM
                var width: CGFloat = 0
                var height: CGFloat = 0
                if let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    width = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                    height = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                }
                
                if settings.splitWebtoon && height > width * 1.5 {
                    if let rawImage = UIImage(contentsOfFile: srcURL.path) {
                        let slices = ImageProcessor.sliceWebtoon(image: rawImage, targetAspectRatio: 1.33)
                        if slices.count > 1 {
                            imagesToProcess = slices
                            isSliced = true
                        }
                    }
                } else if width > height * 1.1 {
                    // Automatically slice massive double-page spreads into two separate portraits for Kindle!
                    if let rawImage = UIImage(contentsOfFile: srcURL.path) {
                        let slices = ImageProcessor.sliceSpread(image: rawImage, isManga: settings.mangaMode)
                        if slices.count > 1 {
                            imagesToProcess = slices
                            isSliced = true
                        }
                    }
                }
                
                // B. Evaluate Processing Needs
                let ext = srcURL.pathExtension.lowercased()
                let isUnsafeFormat = !["jpg", "jpeg", "png"].contains(ext)
                let needsCompression = settings.compressionQuality != .high
                let needsEnhancement = settings.imageEnhancement.grayscale || settings.imageEnhancement.autoContrast || settings.imageEnhancement.invertColors || settings.imageEnhancement.brightness != 0 || settings.imageEnhancement.sharpness != 0 || settings.imageEnhancement.vibrance != 0 || settings.imageEnhancement.gamma != 1.0
                
                let needsProcessing = needsCompression || needsEnhancement || settings.optimizeForDevice || settings.trimMargins || isUnsafeFormat
                
                let appendToBatch = { (data: Data, indexToUse: Int, itemSourceURL: URL) in
                    let itemSize = Int64(data.count)
                    let overheadBuffer: Int64 = 500 * 1024
                    
                    let isNoLimit = limit == Int64.max
                    let exceedsLimit = (currentBatchSize + itemSize + overheadBuffer) > limit
                    
                    if !isNoLimit && exceedsLimit && !currentBatch.isEmpty {
                        Logger.shared.log("Auto-Splitting at \(currentBatchSize) bytes (Image: \(indexToUse))", category: "Converter")
                        batches.append(currentBatch)
                        currentBatch = []
                        currentBatchSize = 0
                    }
                    
                    // Immediately write data to disk instead of hoarding in memory
                    let diskURL = sandboxDir.appendingPathComponent("processed_\(UUID().uuidString).jpg")
                    try? data.write(to: diskURL)
                    
                    currentBatch.append((processedDiskURL: diskURL, sourceURL: itemSourceURL, index: indexToUse))
                    currentBatchSize += itemSize
                    globalImageIndex += 1
                }
                
                // Fix 1: Slices — each slice gets its own autoreleasepool so the
                // UIImage pixel buffer and any CIImage/CIContext intermediates are
                // drained before the next slice is decoded. Without this, all N slices
                // (each ~30–80MB uncompressed) accumulate in RAM simultaneously.
                //
                // Fix 4: Pass a synthetic .jpg URL so buildEPUBDirectory correctly
                // labels the media-type as image/jpeg regardless of source format.
                let sliceSourceURL = URL(fileURLWithPath: "slice.jpg")
                if isSliced {
                    for slice in imagesToProcess {
                        var finalData = Data()
                        autoreleasepool {
                            if needsProcessing {
                                let processedImage = ImageProcessor.process(image: slice, settings: settings, isOddPage: globalImageIndex % 2 == 0) ?? slice
                                finalData = processedImage.jpegData(compressionQuality: settings.compressionQuality.value) ?? Data()
                            } else {
                                finalData = slice.jpegData(compressionQuality: 1.0) ?? Data()
                            }
                        } // UIImage + CIImage pipeline freed here before next slice
                        guard !finalData.isEmpty else {
                            Logger.shared.log("Skipping empty slice from \(srcURL.lastPathComponent)", category: "Converter", type: .warning)
                            continue
                        }
                        appendToBatch(finalData, globalImageIndex, sliceSourceURL)
                    }
                } else {
                    // Fix 2: For the non-sliced path, scope processedImage inside
                    // its own block so it is released before finalData escapes.
                    var finalData = Data()
                    autoreleasepool {
                        if needsProcessing {
                            if let processedImage = ImageProcessor.process(imageURL: srcURL, settings: settings, isOddPage: originalIndex % 2 == 0) {
                                let quality = settings.compressionQuality.value
                                finalData = processedImage.jpegData(compressionQuality: quality) ?? Data()
                            }
                            if finalData.isEmpty {
                                finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                            }
                        } else {
                            finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                        }
                    } // processedImage UIImage freed here; only compressed Data escapes
                    guard !finalData.isEmpty else {
                        Logger.shared.log("Skipping unreadable image \(srcURL.lastPathComponent)", category: "Converter", type: .warning)
                        return
                    }
                    appendToBatch(finalData, globalImageIndex, srcURL)
                }
                
                progress(0.1 + (0.4 * Double(originalIndex) / totalCount))
            }
        }
        
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        
        Logger.shared.log("Stage 2 End: Built \(batches.count) batches", category: "Converter")
        return batches.map { chunk in
            chunk.map { (processedDiskURL: $0.processedDiskURL, sourceURL: $0.sourceURL, index: $0.index) }
        }
    }

    // Stage 3 — Build EPUB directory structure...
    private func buildEPUBDirectory(sourceURL: URL, batch: [(processedDiskURL: URL, sourceURL: URL, index: Int)], batchIndex: Int, totalBatches: Int, baseFilename: String, settings: ConversionSettings, coverData: Data?, isCoverOverrideActive: Bool = false) async throws -> URL {
        Logger.shared.log("Stage 3 Start: Building EPUB Directory for Part \(batchIndex + 1)", category: "Converter")
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory // Or pass it if needed, but we can generate a unique one
        
        let batchDir = tempDir.appendingPathComponent("EPUB_Part_\(UUID().uuidString)")
        let oebpsDir = batchDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        let cssDir = oebpsDir.appendingPathComponent("css")
        let metaInfDir = batchDir.appendingPathComponent("META-INF")
        
        try? fileManager.removeItem(at: batchDir)
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        let containerXML = EPUBManifestBuilder.containerXML
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        let cssContent = EPUBManifestBuilder.cssContent
        try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
        
        var spineItems: [String] = []
        var manifestItems: [String] = []
        
        let isManga = settings.mangaMode
        
        // Dynamic Cover Generation for Split Volumes
        // hasBadgedCover tracks whether a separate badged cover image has been written.
        var hasBadgedCover = false
        if let coverData = coverData, totalBatches > 1 {
            let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: totalBatches)
            let coverFilename = "badged_cover.jpg"
            try? badgedCoverData.write(to: imagesDir.appendingPathComponent(coverFilename))
            
            // The badged cover image must carry properties="cover-image" so the OPF
            // <meta name="cover" content="cover-image"/> resolves correctly. Kindle's
            // ingestor requires the item referenced by <meta name="cover"> to have
            // this property and fails with E999 if it does not. The duplicate is still
            // suppressed because cover.xhtml (added to the spine below) wraps it —
            // auto-injection only fires when a cover-image item has NO spine XHTML wrapper.
            manifestItems.append("<item id=\"cover-image\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
            // Write cover.xhtml so the cover-image manifest item is referenced from the spine.
            // Kindle Cloud auto-injects a duplicate cover page for any cover-image item that
            // is NOT in the spine — this cover.xhtml prevents that auto-injection.
            let coverXHTML = EPUBManifestBuilder.buildCoverXHTML(coverFilename: coverFilename, isManga: isManga)
            try coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
            manifestItems.append("<item id=\"cover-page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>")
            let coverSpreadTag: String
            if settings.linkCoverAsSpread {
                coverSpreadTag = isManga ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
            } else {
                coverSpreadTag = ""
            }
            spineItems.append("<itemref idref=\"cover-page\"\(coverSpreadTag)/>")
            hasBadgedCover = true
        }
        
        // ── Pre-flight: fetch SwiftData metadata once on the MainActor before
        //    entering the heavy image-processing loop. This avoids the crash that
        //    occurs when MainActor.run is called mid-conversion while the owning
        //    view may be deallocating.
        let (bookUUID, metadataInfo): (String, (seriesID: String?, seriesName: String?, issueNum: Int?)) = await MainActor.run {
            let context = InksyncProApp.sharedModelContainer.mainContext
            let urlStr = sourceURL.absoluteString
            let nameStr = sourceURL.lastPathComponent
            let descriptor = FetchDescriptor<SDConvertedPDF>()
            if let pdfs = try? context.fetch(descriptor),
               let pdf = pdfs.first(where: { $0.url.absoluteString == urlStr || $0.name == nameStr }) {
                let seriesID = pdf.metadata.universalSeriesID
                let seriesName = pdf.metadata.series
                let issueNum = Int(pdf.metadata.issueNumber ?? "")
                return (pdf.id.uuidString, (seriesID, seriesName, issueNum))
            }
            return (UUID().uuidString, (nil, nil, nil))
        }

        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        
        // Determine firstPageHref for nav.xhtml BEFORE writing it.
        // Multi-batch: badged cover.xhtml is the first spine item → point here.
        // Single-volume: page_0001.xhtml (containing img_1 / the cover image) is
        // the entry-point. Kindle extracts the thumbnail from the properties="cover-image"
        // manifest attribute on img_1; no separate cover.xhtml is needed.
        let firstPageHref = hasBadgedCover ? "text/cover.xhtml" : "text/page_0001.xhtml"
        let navContent = EPUBManifestBuilder.buildNavContent(firstPageHref: firstPageHref, isManga: isManga)
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let ncxContent = EPUBManifestBuilder.buildNCXContent(
            bookUUID: bookUUID,
            baseFilename: baseFilename,
            firstPageHref: firstPageHref
        )
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: String.Encoding.utf8)
        
        var currentChunkImages: [String] = []
        var chunkIndex = 0
        
        // Multi-batch: cover.xhtml occupies spine slot 1, so content pages start at 2.
        // Single-volume: img_1 IS page 1, content pages start at 1.
        var globalPageCounter = hasBadgedCover ? 2 : 1
        
        for (localIndex, item) in batch.enumerated() {
            let isFirstImageOfBook = (localIndex == 0 && batchIndex == 0)
            
            let trueExt = (item.sourceURL.pathExtension.lowercased() == "png") ? "png" : "jpg"
            let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
            
            let newImageName = String(format: "image_%04d.%@", localIndex + 1, trueExt)
            let destURL = imagesDir.appendingPathComponent(newImageName)
            
            if isFirstImageOfBook && isCoverOverrideActive && !hasBadgedCover, let coverData = coverData {
                try? coverData.write(to: destURL)
            } else {
                try? fileManager.copyItem(at: item.processedDiskURL, to: destURL)
            }
            
            // img_1 (the first image of the first batch) carries properties="cover-image"
            // so the OPF <meta name="cover" content="img_1"/> is consistent and Kindle can
            // extract a thumbnail. img_1 also appears as page_0001.xhtml in the spine —
            // the manifest property and the spine XHTML are independent roles and do not
            // conflict. NOTE: this causes Kindle to show a duplicate cover page (auto-injected
            // thumbnail + page_0001 both show the cover image). That is a known cosmetic
            // limitation separate from the E999 structural validation error.
            let properties = isFirstImageOfBook ? "properties=\"cover-image\"" : ""
            let propString = properties.isEmpty ? "" : " \(properties)"
            manifestItems.append("<item id=\"img_\(localIndex+1)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\"\(propString)/>")
            
            currentChunkImages.append(newImageName)
            
            // Generate DOM Page
            chunkIndex += 1
            let chunkXHTML = CBZToEPUBConverter.generateChunkXHTML(
                chunkIndex: chunkIndex,
                images: currentChunkImages,
                title: "Page \(chunkIndex)",
                bookUUID: bookUUID,
                pageIndex: item.index,
                isManga: isManga
            )
            let chunkName = String(format: "page_%04d.xhtml", chunkIndex)
            try chunkXHTML.write(to: textDir.appendingPathComponent(chunkName), atomically: true, encoding: .utf8)
            manifestItems.append("<item id=\"page_\(chunkIndex)\" href=\"text/\(chunkName)\" media-type=\"application/xhtml+xml\"/>")
            
            // Universally Apply Advanced Landscape Spread Tagging (RTL vs LTR)
            let spreadTag: String
            if settings.linkCoverAsSpread {
                if isManga {
                    // RTL Manga Sequence: Cover (page 1) is Right, Page 2 is Left, Page 3 is Right
                    spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                } else {
                    // LTR Western Sequence: Cover (page 1) is Left, Page 2 is Right, Page 3 is Left
                    spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                }
            } else {
                if globalPageCounter == 1 {
                    spreadTag = "" // Cover stands alone centered
                } else if isManga {
                    // RTL Manga Sequence: Page 2 is Right, Page 3 is Left
                    spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                } else {
                    // LTR Western Sequence: Page 2 is Left, Page 3 is Right
                    spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                }
            }
            
            spineItems.append("<itemref idref=\"page_\(chunkIndex)\"\(spreadTag)/>")
            
            globalPageCounter += 1
            currentChunkImages.removeAll()
        }
        
        // embedCharacterGlossary uses the pre-fetched metadataInfo — no MainActor round-trip needed.
        if settings.embedCharacterGlossary {
            let glossaryHTML = await MainActor.run {
                CharacterGlossaryBuilder.shared.buildGlossaryHTML(
                    seriesIDString: metadataInfo.seriesID,
                    seriesName: metadataInfo.seriesName ?? baseFilename,
                    issueNumber: metadataInfo.issueNum
                )
            }
            
            if let html = glossaryHTML {
                let glossaryFilename = "glossary.xhtml"
                let glossaryURL = textDir.appendingPathComponent(glossaryFilename)
                try? html.write(to: glossaryURL, atomically: true, encoding: .utf8)
                
                manifestItems.append("<item id=\"character-glossary\" href=\"text/\(glossaryFilename)\" media-type=\"application/xhtml+xml\"/>")
                spineItems.append("<itemref idref=\"character-glossary\"/>")
            }
        }
        
        // For single-volume: cover image is img_1 (with properties="cover-image").
        // For multi-batch: the badged cover written above is "cover-image".
        let coverMetaID = (totalBatches > 1 && hasBadgedCover) ? "cover-image" : "img_1"
        let opfContent = EPUBManifestBuilder.buildOPFContent(
            bookUUID: bookUUID,
            baseFilename: baseFilename,
            coverMetaID: coverMetaID,
            manifestItems: manifestItems,
            spineItems: spineItems,
            isManga: settings.mangaMode,
            firstPageHref: firstPageHref
        )
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        Logger.shared.log("Stage 3 End: Built directory at \(batchDir.lastPathComponent)", category: "Converter")
        return batchDir
    }

    // Stage 4 — Zip EPUB directory into a final .epub file.
    // ZIPFoundation performs synchronous disk I/O: move it off the Swift cooperative
    // thread pool via DispatchQueue.global so we don't starve other async tasks.
    private func packageEPUB(batchDir: URL, outputName: String) async throws -> URL {
        Logger.shared.log("Stage 4 Start: Packaging EPUB \(outputName)", category: "Converter")
        let fileManager = FileManager.default
        // batchDir holds the full unzipped EPUB tree — must always be cleaned up.
        // The defer fires after the returned URL is captured by the caller, which is safe
        // because the EPUB is written to Documents/ not inside batchDir.
        defer { try? fileManager.removeItem(at: batchDir) }

        let safeName = outputName.map { char -> String in
            if char.isLetter || char.isNumber || char == "-" { return String(char) }
            else if char == "_" || char.isWhitespace { return " " }
            else { return "" }
        }.joined()
        
        let outputFilename = (safeName.isEmpty ? "comic" : safeName) + ".epub"
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "Converter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Documents directory not found"])
        }
        let outputURL = docDir.appendingPathComponent(outputFilename)

        // Capture values so they are Sendable across the continuation boundary.
        let capturedBatchDir = batchDir
        let capturedOutputURL = outputURL

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if FileManager.default.fileExists(atPath: capturedOutputURL.path) {
                        try FileManager.default.removeItem(at: capturedOutputURL)
                    }

                    guard let archive = try? Archive(url: capturedOutputURL, accessMode: .create, pathEncoding: .utf8) else {
                        throw NSError(domain: "Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create EPUB archive"])
                    }

                    let mimetypePath = capturedBatchDir.appendingPathComponent("mimetype")
                    try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
                    // mimetype MUST be the first entry and stored uncompressed per EPUB spec §3.3
                    try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)

                    let containerPath = capturedBatchDir.appendingPathComponent("META-INF/container.xml")
                    try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .none)

                    let oebpsDir = capturedBatchDir.appendingPathComponent("OEBPS")
                    if let enumerator = FileManager.default.enumerator(at: oebpsDir, includingPropertiesForKeys: nil) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                            if resourceValues.isDirectory == true { continue }
                            let normalizedFile = fileURL.path.replacingOccurrences(of: "\\", with: "/")
                            let normalizedBase = capturedBatchDir.path.replacingOccurrences(of: "\\", with: "/")
                            let prefix = normalizedBase.hasSuffix("/") ? normalizedBase : normalizedBase + "/"
                            let relativePath = normalizedFile.replacingOccurrences(of: prefix, with: "")
                            try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        Logger.shared.log("About to analyze EPUB structure for: \(capturedOutputURL.lastPathComponent)", category: "Debug")
        Logger.shared.logEPUBStructure(at: capturedOutputURL)
        PhysicalFileSystemRouter.excludeFromBackup(at: capturedOutputURL)
        Logger.shared.log("Stage 4 End: EPUB Packaged at \(capturedOutputURL.lastPathComponent)", category: "Converter")
        return capturedOutputURL
    }

    static func generateChunkXHTML(chunkIndex: Int, images: [String], title: String, width: Int? = nil, height: Int? = nil, bookUUID: String? = nil, pageIndex: Int? = nil, isManga: Bool = false) -> String {
        return EPUBManifestBuilder.buildChunkXHTML(chunkIndex: chunkIndex, images: images, title: title, bookUUID: bookUUID, pageIndex: pageIndex, isManga: isManga)
    }
}
