import SwiftUI
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]?, progress: @escaping (Double) -> Void) async throws -> [URL] {
        Logger.shared.log("Starting Enterprise Conversion (No TOC). Manual Manifest: \(manualManifest?.count ?? 0) pages", category: "Converter")
        
        let fileManager = FileManager.default
        
        // Strip ALL extensions
        var baseFilename = sourceURL.lastPathComponent
        while !baseFilename.isEmpty && baseFilename.contains(".") {
            let stripped = (baseFilename as NSString).deletingPathExtension
            if stripped == baseFilename { break } // No more extensions
            baseFilename = stripped
        }
        
        // Stage 1
        progress(0.1)
        let extractResult = try await extractArchive(from: sourceURL)
        let tempDir = extractResult.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let originalImageURLs = extractResult.imageURLs
        
        // Stage 2
        let batches = try await processAndBatch(imageURLs: originalImageURLs, settings: settings, progress: progress)
        
        // Stage 3 & 4
        var generatedFiles: [URL] = []
        var globalFirstBatchCoverData: Data? = nil
        
        for (batchIndex, batch) in batches.enumerated() {
            let partSuffix = batches.count > 1 ? " (pt \(batchIndex + 1))" : ""
            let epubName = baseFilename + partSuffix
            
            if batchIndex == 0, let firstImage = batch.first {
                globalFirstBatchCoverData = firstImage.data
            }
            
            let batchDir = try await buildEPUBDirectory(
                batch: batch,
                batchIndex: batchIndex,
                totalBatches: batches.count,
                baseFilename: epubName,
                settings: settings,
                coverData: globalFirstBatchCoverData
            )
            
            let outputURL = try await packageEPUB(batchDir: batchDir, outputName: epubName)
            generatedFiles.append(outputURL)
            
            progress(0.5 + (0.5 * Double(batchIndex + 1) / Double(batches.count)))
        }
        
        progress(1.0)
        return generatedFiles
    }
    
    // Stage 1 — Extract archive to temp directory, return sorted image URLs
    private func extractArchive(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        Logger.shared.log("Stage 1 Start: Extracting \(sourceURL.lastPathComponent)", category: "Converter")
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        guard !extractionResult.imageURLs.isEmpty else {
            throw NSError(domain: "Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        Logger.shared.log("Stage 1 End: Extracted \(extractionResult.imageURLs.count) images", category: "Converter")
        return (workingDir: extractionResult.workingDir, imageURLs: extractionResult.imageURLs)
    }

    // Stage 2 — Process and batch images...
    private func processAndBatch(imageURLs: [URL], settings: ConversionSettings, progress: @escaping (Double) -> Void) async throws -> [[(data: Data, sourceURL: URL, index: Int)]] {
        Logger.shared.log("Stage 2 Start: Processing and Batching", category: "Converter")
        var batches: [[(url: URL, index: Int, data: Data)]] = []
        var currentBatch: [(url: URL, index: Int, data: Data)] = []
        var currentBatchSize: Int64 = 0
        let limit = settings.splitMode.limit
        
        let totalCount = Double(imageURLs.count)
        var globalImageIndex = 0
        
        for (originalIndex, srcURL) in imageURLs.enumerated() {
            // A. Check for Webtoon Slicing
            var imagesToProcess: [UIImage] = []
            var isSliced = false
            
            if settings.splitWebtoon, let rawImage = UIImage(contentsOfFile: srcURL.path) {
                let slices = ImageProcessor.sliceWebtoon(image: rawImage, targetAspectRatio: 1.33)
                if slices.count > 1 {
                    imagesToProcess = slices
                    isSliced = true
                }
            }
            
            // B. Evaluate Processing Needs
            let ext = srcURL.pathExtension.lowercased()
            let isUnsafeFormat = !["jpg", "jpeg", "png"].contains(ext)
            let needsCompression = settings.compressionQuality != .high
            let needsEnhancement = settings.imageEnhancement.grayscale || settings.imageEnhancement.autoContrast || settings.imageEnhancement.invertColors || settings.imageEnhancement.brightness != 0 || settings.imageEnhancement.sharpness != 0 || settings.imageEnhancement.vibrance != 0 || settings.imageEnhancement.gamma != 1.0
            
            let needsProcessing = needsCompression || needsEnhancement || settings.optimizeForDevice || settings.trimMargins || isUnsafeFormat
            
            let appendToBatch = { (data: Data, indexToUse: Int) in
                let itemSize = Int64(data.count)
                let overheadBuffer: Int64 = 500 * 1024 
                
                let isNoLimit = limit == Int64.max
                let exceedsLimit = (currentBatchSize + itemSize + overheadBuffer) > limit
                
                if !isNoLimit && exceedsLimit && !currentBatch.isEmpty {
                    Logger.shared.log("ΓÜá∩╕Å Auto-Splitting at \(currentBatchSize) bytes (Image: \(indexToUse))", category: "Converter")
                    batches.append(currentBatch)
                    currentBatch = []
                    currentBatchSize = 0
                }
                
                currentBatch.append((url: srcURL, index: indexToUse, data: data))
                currentBatchSize += itemSize
                globalImageIndex += 1
            }
            
            // C. Process and Append
            if isSliced {
                for slice in imagesToProcess {
                    var finalData: Data
                    if needsProcessing {
                        let processedImage = ImageProcessor.process(image: slice, settings: settings) ?? slice
                        finalData = processedImage.jpegData(compressionQuality: settings.compressionQuality.value) ?? Data()
                    } else {
                        finalData = slice.jpegData(compressionQuality: 1.0) ?? Data()
                    }
                    appendToBatch(finalData, globalImageIndex)
                }
            } else {
                var finalData: Data
                if needsProcessing {
                    if let processedImage = ImageProcessor.process(imageURL: srcURL, settings: settings) {
                        let quality = settings.compressionQuality.value
                        finalData = processedImage.jpegData(compressionQuality: quality) ?? (try? Data(contentsOf: srcURL)) ?? Data()
                    } else {
                        finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                    }
                } else {
                     finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                }
                appendToBatch(finalData, globalImageIndex)
            }
            
            progress(0.1 + (0.4 * Double(originalIndex) / totalCount))
        }
        
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        
        Logger.shared.log("Stage 2 End: Built \(batches.count) batches", category: "Converter")
        return batches.map { chunk in
            chunk.map { (data: $0.data, sourceURL: $0.url, index: $0.index) }
        }
    }

    // Stage 3 — Build EPUB directory structure...
    private func buildEPUBDirectory(batch: [(data: Data, sourceURL: URL, index: Int)], batchIndex: Int, totalBatches: Int, baseFilename: String, settings: ConversionSettings, coverData: Data?) async throws -> URL {
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
        
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body { margin: 0; padding: 0; background-color: #000000; }
        .content-container { display: flex; justify-content: center; align-items: center; width: 100vw; height: 100vh; margin: 0; padding: 0; }
        .page { position: absolute; width: 100%; height: 100%; margin: 0; padding: 0; }
        img.comic-page { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
        a.app-amzn-magnify { display: block; position: absolute; z-index: 10; text-decoration: none; background: transparent; }
        .panel-source { position: absolute; width: 100%; height: 100%; background: transparent; }
        .panel-target { position: absolute; z-index: 5; pointer-events: none; background: transparent; }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
        
        var spineItems: [String] = []
        var manifestItems: [String] = []
        
        // Dynamic Cover Generation for Split Volumes
        if let coverData = coverData, totalBatches > 1 {
            let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: totalBatches)
            let coverFilename = "badged_cover.jpg"
            try? badgedCoverData.write(to: imagesDir.appendingPathComponent(coverFilename))
            
            manifestItems.append("<item id=\"cover-image\" href=\"images/\\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
            manifestItems.append("<item id=\"cover-page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"cover-page\"/>")
            
            let coverXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Cover</title><style type="text/css">
            body { margin: 0; padding: 0; text-align: center; background-color: #000; }
            img { max-width: 100%; max-height: 100%; height: auto; }
            </style></head>
            <body><img src="../images/\\(coverFilename)" alt="Cover"/></body>
            </html>
            """
            try? coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
        }
        
        let bookUUID = UUID().uuidString
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
        <head><title>Navigation</title><meta charset="utf-8" /></head>
        <body><nav epub:type="toc" id="toc"><h1>Table of Contents</h1><ol><li><a href="text/page_0001.xhtml">Start Reading</a></li></ol></nav></body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: String.Encoding.utf8)
        
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:\\(bookUUID)"/></head>
            <docTitle><text>\\(baseFilename)</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page_0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: String.Encoding.utf8)
        
        let chunkSize = 20
        var currentChunkImages: [String] = []
        var chunkIndex = 0
        
        if batchIndex > 0, let coverData = coverData {
            let coverName = "cover_reused.jpg"
            let coverURL = imagesDir.appendingPathComponent(coverName)
            try? coverData.write(to: coverURL)
            manifestItems.append("<item id=\"cover_reused_img\" href=\"images/\\(coverName)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
            currentChunkImages.append(coverName)
        }
        
        for (localIndex, item) in batch.enumerated() {
            let trueExt = (item.sourceURL.pathExtension.lowercased() == "png") ? "png" : "jpg"
            let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
            
            let newImageName = String(format: "image_%04d.%@", localIndex + 1, trueExt)
            let destURL = imagesDir.appendingPathComponent(newImageName)
            try item.data.write(to: destURL)
            
            let properties = (localIndex == 0 && batchIndex == 0) ? "properties=\"cover-image\"" : ""
            manifestItems.append("<item id=\"img_\\(localIndex+1)\" href=\"images/\\(newImageName)\" media-type=\"image/\\(safeExt)\" \\(properties)/>")
            currentChunkImages.append(newImageName)
            
            if currentChunkImages.count >= chunkSize || localIndex == batch.count - 1 {
                chunkIndex += 1
                let chunkXHTML = CBZToEPUBConverter.generateChunkXHTML(
                    chunkIndex: chunkIndex,
                    images: currentChunkImages,
                    title: "Part \\(chunkIndex)"
                )
                let chunkName = String(format: "chunk_%04d.xhtml", chunkIndex)
                try chunkXHTML.write(to: textDir.appendingPathComponent(chunkName), atomically: true, encoding: .utf8)
                manifestItems.append("<item id=\"chunk_\\(chunkIndex)\" href=\"text/\\(chunkName)\" media-type=\"application/xhtml+xml\"/>")
                spineItems.append("<itemref idref=\"chunk_\\(chunkIndex)\"/>")
                currentChunkImages.removeAll()
            }
        }
        
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\\(bookUUID)</dc:identifier>
                <dc:title>\\(baseFilename.xmlEscaped())</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\\(ISO8601DateFormatter().string(from: Date()))</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta name="cover" content="\\(batchIndex > 0 && coverData != nil ? "cover_reused_img" : "img_1")"/>
            </metadata>
            <manifest>
                \\(manifestItems.joined(separator: "\\n        "))
            </manifest>
            <spine toc="ncx" page-progression-direction="\\(settings.mangaMode ? "rtl" : "ltr")">
                \\(spineItems.joined(separator: "\\n        "))
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        Logger.shared.log("Stage 3 End: Built directory at \(batchDir.lastPathComponent)", category: "Converter")
        return batchDir
    }

    // Stage 4 — Zip EPUB...
    private func packageEPUB(batchDir: URL, outputName: String) async throws -> URL {
        Logger.shared.log("Stage 4 Start: Packaging EPUB \(outputName)", category: "Converter")
        let fileManager = FileManager.default
        let safeName = outputName.map { char -> String in
            if char.isLetter || char.isNumber || char == "-" { return String(char) }
            else if char == "_" || char.isWhitespace { return " " }
            else { return "" }
        }.joined()
        
        let outputFilename = (safeName.isEmpty ? "comic" : safeName) + ".epub"
        let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        
        do {
            guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
                throw NSError(domain: "Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create EPUB archive"])
            }
            
            let mimetypePath = batchDir.appendingPathComponent("mimetype")
            try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
            try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
            
            let containerPath = batchDir.appendingPathComponent("META-INF/container.xml")
            try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .deflate)
            
            let oebpsDir = batchDir.appendingPathComponent("OEBPS")
            let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: nil)!
            while let fileURL = enumerator.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory == true { continue }
                
                if let relativePath = fileURL.path.components(separatedBy: "\\(batchDir.path)/").last {
                    try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                }
            }
        } catch {
            throw error
        }
        
        Logger.shared.log("About to analyze EPUB structure for: \\(outputURL.lastPathComponent)", category: "Debug")
        Logger.shared.logEPUBStructure(at: outputURL)
        Logger.shared.log("Stage 4 End: EPUB Packaged at \\(outputURL.lastPathComponent)", category: "Converter")
        return outputURL
    }

    static func generateChunkXHTML(chunkIndex: Int, images: [String], title: String) -> String {
        let imageElements = images.enumerated().map { i, imageName in
            """
                <div class="page">
                    <img src="../images/\\(imageName)" class="page-image" alt="Page Image"/>
                </div>
            """
        }.joined(separator: "\\n")
        
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta charset="UTF-8"/>
    <title>\\(title)</title>
    <style>
        @page { margin: 0; padding: 0; }
        @media amzn-kf8 { body { margin: 0 !important; padding: 0 !important; } }
        html, body { margin: 0; padding: 0; background-color: #000000; }
        .chunk-container { width: 100%; column-gap: 0; -webkit-column-gap: 0; }
        .page { text-align: center; page-break-inside: avoid; margin: 0; padding: 0; }
        .page-image { max-width: 100%; max-height: 100vh; height: auto; object-fit: contain; }
    </style>
</head>
<body>
    <div class="chunk-container">
    \\(imageElements)
    </div>
</body>
</html>
"""
    }
    
    // MARK: - KFX Export Pipeline
    
    /// Builds a .inksync KFX-ready export package for desktop conversion.
    func buildKFXPackage(
        sourceURL: URL,
        settings: ConversionSettings,
        metadata: PDFMetadata,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        Logger.shared.log("Stage 1 Start: Extracting \\(sourceURL.lastPathComponent) for KFX", category: "Converter")
        progress(0.1)
        
        let fileManager = FileManager.default
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        let tempDir = extractionResult.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }
        
        guard !extractionResult.imageURLs.isEmpty else {
            throw NSError(domain: "Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        Logger.shared.log("Stage 1 End: Extracted \\(extractionResult.imageURLs.count) images", category: "Converter")
        
        Logger.shared.log("Stage 2 Start: Processing Images for KFX", category: "Converter")
        let packageDir = tempDir.appendingPathComponent("KFX_Package_\\(UUID().uuidString)")
        let imagesDir = packageDir.appendingPathComponent("images")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        
        let totalCount = Double(extractionResult.imageURLs.count)
        var globalImageIndex = 0
        
        for (originalIndex, srcURL) in extractionResult.imageURLs.enumerated() {
            let ext = srcURL.pathExtension.lowercased()
            let isUnsafeFormat = !["jpg", "jpeg", "png"].contains(ext)
            let needsCompression = settings.compressionQuality != .high
            let needsEnhancement = settings.imageEnhancement.grayscale || settings.imageEnhancement.autoContrast || settings.imageEnhancement.invertColors || settings.imageEnhancement.brightness != 0 || settings.imageEnhancement.sharpness != 0 || settings.imageEnhancement.vibrance != 0 || settings.imageEnhancement.gamma != 1.0
            
            let needsProcessing = needsCompression || needsEnhancement || settings.optimizeForDevice || settings.trimMargins || isUnsafeFormat
            
            var processedData: Data?
            if needsProcessing {
                if let processedImage = ImageProcessor.process(imageURL: srcURL, settings: settings) {
                    processedData = processedImage.jpegData(compressionQuality: settings.compressionQuality.value)
                }
            } else {
                processedData = try? Data(contentsOf: srcURL)
            }
            
            guard let data = processedData else { continue }
            
            let trueExt = (ext == "png" && !needsProcessing) ? "png" : "jpg"
            let newImageName = String(format: "page_%04d.%@", globalImageIndex + 1, trueExt)
            let destURL = imagesDir.appendingPathComponent(newImageName)
            try data.write(to: destURL)
            
            globalImageIndex += 1
            progress(0.1 + (0.7 * Double(originalIndex) / totalCount))
        }
        Logger.shared.log("Stage 2 End: Processed \\(globalImageIndex) images", category: "Converter")
        
        Logger.shared.log("Stage 3 Start: Building scripts and metadata", category: "Converter")
        
        let titleStr = metadata.title.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : metadata.title
        var authorStr = ""
        if let writer = metadata.writer, !writer.isEmpty {
            authorStr = writer
        } else if let author = metadata.author, !author.isEmpty {
            authorStr = author
        }
        
        let directionStr = settings.mangaMode ? "rtl" : "ltr"
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let sourceFilename = sourceURL.deletingPathExtension().lastPathComponent
        
        let metadataJSON = """
        {
          "title": "\\(titleStr.replacingOccurrences(of: "\\\"", with: "\\\\\\\""))",
          "author": "\\(authorStr.replacingOccurrences(of: "\\\"", with: "\\\\\\\""))",
          "reading_direction": "\\(directionStr)",
          "page_count": \\(globalImageIndex),
          "source_filename": "\\(sourceFilename.replacingOccurrences(of: "\\\"", with: "\\\\\\\""))",
          "inksync_version": "1.0",
          "generated_at": "\\(generatedAt)"
        }
        """
        
        try metadataJSON.write(to: packageDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try CBZToEPUBConverter.convertShContent.write(to: packageDir.appendingPathComponent("convert.sh"), atomically: true, encoding: .utf8)
        try CBZToEPUBConverter.convertBatContent.write(to: packageDir.appendingPathComponent("convert.bat"), atomically: true, encoding: .utf8)
        try CBZToEPUBConverter.buildEpubPyContent.write(to: packageDir.appendingPathComponent("build_epub.py"), atomically: true, encoding: .utf8)
        try CBZToEPUBConverter.readmeTxtContent.write(to: packageDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        
        Logger.shared.log("Stage 3 End: Scripts injected", category: "Converter")
        
        Logger.shared.log("Stage 4 Start: Zipping .inksync package", category: "Converter")
        progress(0.85)
        
        let safeName = titleStr.map { char -> String in
            if char.isLetter || char.isNumber || char == "-" { return String(char) }
            else if char == "_" || char.isWhitespace { return " " }
            else { return "" }
        }.joined()
        
        let outputFilename = (safeName.isEmpty ? "comic" : safeName) + ".inksync"
        let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        
        do {
            guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
                throw NSError(domain: "Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create KFX package archive"])
            }
            
            let mimetypePath = packageDir.appendingPathComponent("mimetype")
            try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
            try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
            
            let enumerator = fileManager.enumerator(at: packageDir, includingPropertiesForKeys: nil)!
            while let fileURL = enumerator.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory == true { continue }
                
                if fileURL.lastPathComponent == "mimetype" { continue }
                
                if let relativePath = fileURL.path.components(separatedBy: "\\(packageDir.path)/").last {
                    try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                }
            }
        } catch {
            throw error
        }
        
        Logger.shared.log("Stage 4 End: Created \\(outputFilename)", category: "Converter")
        progress(1.0)
        return outputURL
    }
    
    // MARK: - Script Constants
    
    private static let convertShContent = #"""
    #!/bin/bash
    # InkSync Pro — KFX Conversion Script (Mac/Linux)
    # Requirements: Kindle Previewer 3, Calibre with KFX Output plugin
    # Usage: bash convert.sh

    set -e

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IMAGES_DIR="$SCRIPT_DIR/images"
    METADATA="$SCRIPT_DIR/metadata.json"

    # Parse metadata
    TITLE=$(python3 -c "import json,sys; d=json.load(open('$METADATA')); print(d['title'])")
    DIRECTION=$(python3 -c "import json,sys; d=json.load(open('$METADATA')); print(d['reading_direction'])")

    SAFE_TITLE=$(echo "$TITLE" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    OUTPUT_DIR="$SCRIPT_DIR/output"
    EPUB_PATH="$OUTPUT_DIR/${SAFE_TITLE}.epub"
    KPF_PATH="$OUTPUT_DIR/${SAFE_TITLE}.kpf"
    KFX_PATH="$OUTPUT_DIR/${SAFE_TITLE}.kfx"

    mkdir -p "$OUTPUT_DIR"

    echo "=== InkSync Pro KFX Converter ==="
    echo "Title: $TITLE"
    echo "Reading direction: $DIRECTION"
    echo ""

    # Step 1: Build EPUB from images
    echo "[1/3] Building EPUB from images..."
    python3 "$SCRIPT_DIR/build_epub.py" \
      --images "$IMAGES_DIR" \
      --output "$EPUB_PATH" \
      --title "$TITLE" \
      --direction "$DIRECTION"
    echo "      EPUB created: $EPUB_PATH"

    # Step 2: Convert EPUB to KPF via Kindle Previewer CLI
    echo "[2/3] Converting EPUB to KPF via Kindle Previewer..."
    KP_CLI="/Applications/Kindle Previewer 3.app/Contents/MacOS/kindlepreviewer"
    if [ ! -f "$KP_CLI" ]; then
      echo "ERROR: Kindle Previewer 3 not found at default path."
      echo "       Download from: https://www.amazon.com/Kindle-Previewer/b?node=21381691011"
      exit 1
    fi
    "$KP_CLI" "$EPUB_PATH" -convert -output "$OUTPUT_DIR"
    # Kindle Previewer names the output after the EPUB filename
    KPF_ACTUAL="$OUTPUT_DIR/${SAFE_TITLE}.kpf"
    if [ ! -f "$KPF_ACTUAL" ]; then
      # Some versions output to a subfolder
      KPF_ACTUAL=$(find "$OUTPUT_DIR" -name "*.kpf" | head -1)
    fi
    echo "      KPF created: $KPF_ACTUAL"

    # Step 3: Convert KPF to KFX via Calibre KFX Output plugin
    echo "[3/3] Converting KPF to KFX via Calibre..."
    CALIBRE_DEBUG="/Applications/calibre.app/Contents/MacOS/calibre-debug"
    if [ ! -f "$CALIBRE_DEBUG" ]; then
      echo "ERROR: Calibre not found at default path."
      echo "       Download from: https://calibre-ebook.com/download"
      exit 1
    fi
    "$CALIBRE_DEBUG" -r "KFX Output" -- "$KPF_ACTUAL" "$KFX_PATH"
    echo "      KFX created: $KFX_PATH"

    echo ""
    echo "=== Done! ==="
    echo "Transfer this file to your Kindle:"
    echo "  $KFX_PATH"
    echo ""
    echo "Connect Kindle via USB and copy to the 'documents' folder."
    """#
    
    private static let convertBatContent = #"""
    @echo off
    REM InkSync Pro — KFX Conversion Script (Windows)
    REM Requirements: Kindle Previewer 3, Calibre with KFX Output plugin
    REM Usage: Double-click convert.bat

    setlocal enabledelayedexpansion

    set SCRIPT_DIR=%~dp0
    set IMAGES_DIR=%SCRIPT_DIR%images
    set METADATA=%SCRIPT_DIR%metadata.json
    set OUTPUT_DIR=%SCRIPT_DIR%output

    for /f "delims=" %%i in ('python -c "import json; d=json.load(open(r'%METADATA%')); print(d['title'])"') do set TITLE=%%i
    for /f "delims=" %%i in ('python -c "import json; d=json.load(open(r'%METADATA%')); print(d['reading_direction'])"') do set DIRECTION=%%i

    REM Sanitize title for filename
    set SAFE_TITLE=%TITLE: =_%

    set EPUB_PATH=%OUTPUT_DIR%\%SAFE_TITLE%.epub
    set KFX_PATH=%OUTPUT_DIR%\%SAFE_TITLE%.kfx

    if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

    echo === InkSync Pro KFX Converter ===
    echo Title: %TITLE%
    echo Reading direction: %DIRECTION%
    echo.

    echo [1/3] Building EPUB from images...
    python "%SCRIPT_DIR%build_epub.py" --images "%IMAGES_DIR%" --output "%EPUB_PATH%" --title "%TITLE%" --direction "%DIRECTION%"
    echo       EPUB created: %EPUB_PATH%

    echo [2/3] Converting EPUB to KPF via Kindle Previewer...
    set KP_CLI=%LOCALAPPDATA%\Amazon\Kindle Previewer 3\app\KindlePreviewer.exe
    if not exist "%KP_CLI%" (
      echo ERROR: Kindle Previewer 3 not found.
      echo        Download from: https://www.amazon.com/Kindle-Previewer/b?node=21381691011
      pause
      exit /b 1
    )
    "%KP_CLI%" "%EPUB_PATH%" -convert -output "%OUTPUT_DIR%"

    echo [3/3] Converting KPF to KFX via Calibre...
    set CALIBRE_DEBUG=%PROGRAMFILES%\Calibre2\calibre-debug.exe
    if not exist "%CALIBRE_DEBUG%" (
      echo ERROR: Calibre not found at default path.
      echo        Download from: https://calibre-ebook.com/download
      pause
      exit /b 1
    )
    "%CALIBRE_DEBUG%" -r "KFX Output" -- "%OUTPUT_DIR%\%SAFE_TITLE%.kpf" "%KFX_PATH%"

    echo.
    echo === Done! ===
    echo Transfer this file to your Kindle:
    echo   %KFX_PATH%
    echo.
    echo Connect Kindle via USB and copy to the 'documents' folder.
    pause
    """#
    
    private static let buildEpubPyContent = #"""
    #!/usr/bin/env python3
    """
    InkSync Pro — EPUB builder for KFX pipeline
    Builds a fixed-layout EPUB3 from a folder of sequentially named images.
    Called by convert.sh and convert.bat.
    """
    import argparse, os, shutil, uuid, zipfile
    from datetime import datetime, timezone

    def build_epub(images_dir, output_path, title, direction):
        images = sorted([
            f for f in os.listdir(images_dir)
            if f.lower().endswith(('.jpg', '.jpeg', '.png'))
        ])
        if not images:
            raise SystemExit("ERROR: No images found in images/")

        book_id = str(uuid.uuid4())
        prog_dir = "rtl" if direction == "rtl" else "ltr"
        spread = "landscape" if direction == "rtl" else "landscape"

        work_dir = output_path + "_build"
        os.makedirs(os.path.join(work_dir, "OEBPS", "images"), exist_ok=True)
        os.makedirs(os.path.join(work_dir, "OEBPS", "text"), exist_ok=True)
        os.makedirs(os.path.join(work_dir, "OEBPS", "css"), exist_ok=True)
        os.makedirs(os.path.join(work_dir, "META-INF"), exist_ok=True)

        # mimetype
        with open(os.path.join(work_dir, "mimetype"), "w") as f:
            f.write("application/epub+zip")

        # container.xml
        with open(os.path.join(work_dir, "META-INF", "container.xml"), "w") as f:
            f.write("""<?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>""")

        # CSS
        css = """@page { margin: 0; padding: 0; }
    body { margin: 0; padding: 0; background: #000; }
    .page-container { position: relative; width: 100vw; height: 100vh; overflow: hidden; }
    .comic-page { position: absolute; top: 0; left: 0; width: 100%; height: 100%; object-fit: contain; }"""
        with open(os.path.join(work_dir, "OEBPS", "css", "comic.css"), "w") as f:
            f.write(css)

        manifest_items = []
        spine_items = []
        manifest_items.append('<item id="css" href="css/comic.css" media-type="text/css"/>')
        manifest_items.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        manifest_items.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')

        for i, img_file in enumerate(images):
            ext = os.path.splitext(img_file)[1].lower()
            mime = "image/png" if ext == ".png" else "image/jpeg"
            safe_ext = "png" if ext == ".png" else "jpg"
            new_name = f"image_{i+1:04d}.{safe_ext}"

            shutil.copy(
                os.path.join(images_dir, img_file),
                os.path.join(work_dir, "OEBPS", "images", new_name)
            )

            cover_prop = ' properties="cover-image"' if i == 0 else ""
            manifest_items.append(
                f'<item id="img_{i+1}" href="images/{new_name}" media-type="{mime}"{cover_prop}/>'
            )

            page_xhtml = f"""<?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head>
      <meta charset="UTF-8"/>
      <meta name="viewport" content="width=device-width, height=device-height"/>
      <title>Page {i+1}</title>
      <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
    </head>
    <body>
      <div class="page-container">
        <img src="../images/{new_name}" class="comic-page" alt="Page {i+1}"/>
      </div>
    </body>
    </html>"""
            page_name = f"page_{i+1:04d}.xhtml"
            with open(os.path.join(work_dir, "OEBPS", "text", page_name), "w") as f:
                f.write(page_xhtml)
            manifest_items.append(
                f'<item id="page_{i+1}" href="text/{page_name}" media-type="application/xhtml+xml"/>'
            )
            spine_items.append(f'<itemref idref="page_{i+1}"/>')

        # nav.xhtml
        nav = f"""<?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>Navigation</title><meta charset="utf-8"/></head>
    <body>
      <nav epub:type="toc" id="toc">
        <ol><li><a href="text/page_0001.xhtml">Start Reading</a></li></ol>
      </nav>
    </body>
    </html>"""
        with open(os.path.join(work_dir, "OEBPS", "nav.xhtml"), "w") as f:
            f.write(nav)

        # toc.ncx
        ncx = f"""<?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="urn:uuid:{book_id}"/></head>
      <docTitle><text>{title}</text></docTitle>
      <navMap>
        <navPoint id="navPoint-1" playOrder="1">
          <navLabel><text>Start</text></navLabel>
          <content src="text/page_0001.xhtml"/>
        </navPoint>
      </navMap>
    </ncx>"""
        with open(os.path.join(work_dir, "OEBPS", "toc.ncx"), "w") as f:
            f.write(ncx)

        # content.opf
        modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        opf = f"""<?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf"
             xmlns:epub="http://www.idpf.org/2007/ops"
             unique-identifier="BookID" version="3.0"
             prefix="rendition: http://www.idpf.org/vocab/rendition/#">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="BookID">urn:uuid:{book_id}</dc:identifier>
        <dc:title>{title}</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">{modified}</meta>
        <meta property="rendition:layout">pre-paginated</meta>
        <meta property="rendition:spread">{spread}</meta>
        <meta property="rendition:orientation">portrait</meta>
        <meta name="cover" content="img_1"/>
      </metadata>
      <manifest>
        {"    ".join(manifest_items)}
      </manifest>
      <spine toc="ncx" page-progression-direction="{prog_dir}">
        {"    ".join(spine_items)}
      </spine>
    </package>"""
        with open(os.path.join(work_dir, "OEBPS", "content.opf"), "w") as f:
            f.write(opf)

        # Package as EPUB (mimetype first, uncompressed)
        if os.path.exists(output_path):
            os.remove(output_path)
        with zipfile.ZipFile(output_path, "w") as zf:
            zf.write(
                os.path.join(work_dir, "mimetype"), "mimetype",
                compress_type=zipfile.ZIP_STORED
            )
            for root, dirs, files in os.walk(work_dir):
                for file in files:
                    if file == "mimetype":
                        continue
                    abs_path = os.path.join(root, file)
                    rel_path = os.path.relpath(abs_path, work_dir)
                    zf.write(abs_path, rel_path, compress_type=zipfile.ZIP_DEFLATED)

        shutil.rmtree(work_dir)
        print(f"EPUB built: {output_path} ({len(images)} pages)")

    if __name__ == "__main__":
        parser = argparse.ArgumentParser()
        parser.add_argument("--images", required=True)
        parser.add_argument("--output", required=True)
        parser.add_argument("--title", required=True)
        parser.add_argument("--direction", required=True)
        args = parser.parse_args()
        build_epub(args.images, args.output, args.title, args.direction)
    """#
    
    private static let readmeTxtContent = #"""
    InkSync Pro — KFX Export Package
    =================================

    This package contains your comic ready for final KFX conversion.
    KFX is required for correct display on Kindle firmware 5.19.2+.

    WHAT YOU NEED ON YOUR COMPUTER
    -------------------------------
    1. Kindle Previewer 3
       Download: https://www.amazon.com/Kindle-Previewer/b?node=21381691011

    2. Calibre (free)
       Download: https://calibre-ebook.com/download

    3. Calibre KFX Output Plugin
       In Calibre: Preferences > Plugins > Get new plugins > search "KFX Output"

    HOW TO CONVERT
    --------------
    Mac/Linux:  Open Terminal, drag convert.sh into it, press Enter
    Windows:    Double-click convert.bat

    The final .kfx file will appear in the output/ folder.

    HOW TO TRANSFER TO KINDLE
    --------------------------
    1. Connect your Kindle via USB
    2. Open the Kindle drive on your computer
    3. Copy the .kfx file into the 'documents' folder
    4. Eject Kindle safely

    The book will appear in your Kindle library.

    WHY IS THIS NEEDED?
    -------------------
    Kindle firmware 5.19.2 introduced a regression affecting all sideloaded
    comic/manga files. KFX format is unaffected and provides the same full-quality
    panel navigation as purchased Amazon comics.
    """#
}
