import SwiftUI
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]?, progress: @escaping (Double) -> Void) async throws -> [URL] {
        Logger.shared.log("Starting Enterprise Conversion (No TOC). Manual Manifest: \(manualManifest?.count ?? 0) pages", category: "Converter")
        
        let fileManager = FileManager.default
        
        // Strip ALL extensions (handles cases like "file.cbz.cbz" or "file.epub.cbz")
        var baseFilename = sourceURL.lastPathComponent
        while !baseFilename.isEmpty && baseFilename.contains(".") {
            let stripped = (baseFilename as NSString).deletingPathExtension
            if stripped == baseFilename { break } // No more extensions
            baseFilename = stripped
        }
        
        // 1. Safe Extraction
        progress(0.1)
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        let tempDir = extractionResult.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let originalImageURLs = extractionResult.imageURLs
        guard !originalImageURLs.isEmpty else {
            throw NSError(domain: "Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        
        // 2. Prepare Batches
        var batches: [[(url: URL, index: Int, data: Data)]] = []
        var currentBatch: [(url: URL, index: Int, data: Data)] = []
        var currentBatchSize: Int64 = 0
        let limit = settings.splitMode.limit
        
        // Pre-calculation: 10% progress for analysis/compression
        let totalCount = Double(originalImageURLs.count)
        
        for (index, srcURL) in originalImageURLs.enumerated() {
            // A. Compress/Load Image Data
            var finalData: Data
            
            // Evaluate if we need to process the image: true if ANY enhancements are on, or resizing is needed, or format isn't JPEG/PNG
            let needsCompression = settings.compressionQuality != .high
            let needsEnhancement = settings.imageEnhancement.grayscale || settings.imageEnhancement.autoContrast || settings.imageEnhancement.invertColors || settings.imageEnhancement.brightness != 0 || settings.imageEnhancement.sharpness != 0 || settings.imageEnhancement.vibrance != 0 || settings.imageEnhancement.gamma != 1.0
            
            let ext = srcURL.pathExtension.lowercased()
            let isUnsafeFormat = !["jpg", "jpeg", "png"].contains(ext)
            let needsProcessing = needsCompression || needsEnhancement || settings.optimizeForDevice || settings.trimMargins || isUnsafeFormat
            
            if needsProcessing {
                // Route image through our professional E-Ink enhancement pipeline!
                if let processedImage = ImageProcessor.process(imageURL: srcURL, settings: settings) {
                    let quality = settings.compressionQuality.value
                    finalData = processedImage.jpegData(compressionQuality: quality) ?? (try? Data(contentsOf: srcURL)) ?? Data()
                } else {
                    finalData = (try? Data(contentsOf: srcURL)) ?? Data() // Fallback
                }
            } else {
                 // Safe to copy exact original bytes
                 finalData = (try? Data(contentsOf: srcURL)) ?? Data()
            }
            
            let itemSize = Int64(finalData.count)
            
            // B. Check Split Limit
            // If adding this image exceeds limit AND we have at least one image in batch, split.
            let overheadBuffer: Int64 = 500 * 1024 
            
            // ✅ DEBUG: Trace Splitting Logic
            let isNoLimit = limit == Int64.max
            let exceedsLimit = (currentBatchSize + itemSize + overheadBuffer) > limit
            
            if !isNoLimit && exceedsLimit && !currentBatch.isEmpty {
                Logger.shared.log("⚠️ Auto-Splitting at \(currentBatchSize) bytes (Image: \(index))", category: "Converter")
                batches.append(currentBatch)
                currentBatch = []
                currentBatchSize = 0
            }
            
            currentBatch.append((url: srcURL, index: index, data: finalData))
            currentBatchSize += itemSize
            
            progress(0.1 + (0.4 * Double(index) / totalCount))
        }
        
        // Append last batch
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        
        // 3. Generate Output (EPUB or CBZ)
        var generatedFiles: [URL] = []
        
        // Track resolution from the first image of the first batch for consistency
        var contentSize = CGSize(width: 1080, height: 1920) // Default fallback
        var hasCapturedResolution = false
        var firstBatchCoverData: Data? = nil // ✅ Store original cover for dynamic chunk badges
        
        for (batchIndex, batch) in batches.enumerated() {
            let partSuffix = batches.count > 1 ? " (pt \(batchIndex + 1))" : ""
            let baseName = baseFilename + partSuffix
            
            // Enforce EPUB (Virtual/Region Magnification)
            // ... Existing EPUB Logic ...
            let epubName = baseName
            let batchDir = tempDir.appendingPathComponent("EPUB_Part_\(batchIndex)")
            let oebpsDir = batchDir.appendingPathComponent("OEBPS")
            let imagesDir = oebpsDir.appendingPathComponent("images")
            let textDir = oebpsDir.appendingPathComponent("text")
            let cssDir = oebpsDir.appendingPathComponent("css") // ✅ NEW: CSS Directory
            let metaInfDir = batchDir.appendingPathComponent("META-INF")
            
            try? fileManager.removeItem(at: batchDir)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true) // ✅ Create CSS Dir
            try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
            
            // Standard EPUB Files
            try "application/epub+zip".write(to: batchDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
            let containerXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles>
            </container>
            """
            try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
            
            // If this is the FIRST batch and FIRST image, capture the raw cover so we can stamp it on future parts
            if batchIndex == 0, let firstImage = batch.first {
                firstBatchCoverData = firstImage.data
            }
            .page {
                position: absolute;
                width: 100%;
                height: 100%;
                margin: 0;
                padding: 0;
            }
            var manifestItems = ""
            var spineItems = ""
            var navPoints = ""
            var playOrder = 1
            
            // ✅ Dynamic Cover Generation for Split Volumes
            if let coverData = firstBatchCoverData, batches.count > 1 {
                print("🎨 Dynamically Generating Cover Badge for Part \(batchIndex + 1) of \(batches.count)")
                let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: batches.count)
                
                let coverFilename = "badged_cover.jpg"
                try badgedCoverData.write(to: imagesDir.appendingPathComponent(coverFilename))
                
                // Add cover to manifest
                manifestItems += "<item id=\"cover-image\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>\n"
                manifestItems += "<item id=\"cover-page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
                spineItems += "<itemref idref=\"cover-page\"/>\n"
                
                // Write cover.xhtml
                let coverXHTML = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>Cover</title><style type="text/css">
                body { margin: 0; padding: 0; text-align: center; background-color: #000; }
                img { max-width: 100%; max-height: 100%; height: auto; }
                </style></head>
                <body><img src="../images/\(coverFilename)" alt="Cover"/></body>
                </html>
                """
                try coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
            }
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
            }
            /* Kindle Panel View Overlays */
            a.app-amzn-magnify {
                display: block;
                position: absolute;
                z-index: 10;
                text-decoration: none;
                background: transparent;
            }
            .panel-source {
                position: absolute;
                width: 100%;
                height: 100%;
                background: transparent;
            }
            .panel-target {
                position: absolute;
                z-index: 5;
                pointer-events: none;
                background: transparent;
            }
            """
            try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
            
            var spineItems: [String] = []
            var manifestItems: [String] = []
            
            // ✅ CRITICAL FIX: Pre-Calculate Resolution for Metadata
            // We must know the content size BEFORE generating the OPF/NCX/NAV files.
            // If we wait until the loop, 'widthID' and 'heightID' will be 0, causing Kindle to break.
            if !batch.isEmpty {
                if let firstItem = batch.first, let image = UIImage(data: firstItem.data) {
                    contentSize = image.size
                    hasCapturedResolution = true
                    // Also capture cover if this is the very first batch
                    if batchIndex == 0 { firstBatchCoverData = firstItem.data }
                }
            }
            
            // ✅ Dynamic Cover Generation for Split Volumes
            if let coverData = firstBatchCoverData, batches.count > 1 {
                print("🎨 Dynamically Generating Cover Badge for Part \(batchIndex + 1) of \(batches.count)")
                
                // Let CoverGenerator CoreGraphics handle blending the badge
                let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: batches.count)
                let coverFilename = "badged_cover.jpg"
                try? badgedCoverData.write(to: imagesDir.appendingPathComponent(coverFilename))
                
                // Add cover to manifest
                manifestItems.append("<item id=\"cover-image\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
                manifestItems.append("<item id=\"cover-page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>")
                spineItems.append("<itemref idref=\"cover-page\"/>")
                
                // Write cover.xhtml
                let coverXHTML = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>Cover</title><style type="text/css">
                body { margin: 0; padding: 0; text-align: center; background-color: #000; }
                img { max-width: 100%; max-height: 100%; height: auto; }
                </style></head>
                <body><img src="../images/\(coverFilename)" alt="Cover"/></body>
                </html>
                """
                try? coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
            }
            
            // ✅ Prepare Metadata Identifiers (Now with valid dimensions)
            let widthID = Int(contentSize.width)
            let heightID = Int(contentSize.height)
            let bookUUID = UUID().uuidString
            // Note: writingMode and spreadMode are defined later near OPF generation for strict compliance
            
            // Add CSS to Manifest
            manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
            
            // ✅ VALIDATION FIX: Restore Navigation Documents (Required for EPUB 3 / Kindle Back-Compat)
            // Even if the user doesn't want a VISIBLE TOC, these files are mandatory for the book structure.
            // We use linear="no" in the spine to hide the HTML TOC.
            manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
            manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
            
            // Generate NAV and NCX immediately to ensure they exist for Zipping
            let navContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
            <head>
                <title>Navigation</title>
                <meta charset="utf-8" />
            </head>
            <body>
                <nav epub:type="toc" id="toc">
                    <h1>Table of Contents</h1>
                    <ol>
                        <li><a href="text/page_0001.xhtml">Start Reading</a></li>
                    </ol>
                </nav>
            </body>
            </html>
            """
            try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: String.Encoding.utf8)
            Logger.shared.log("✅ Wrote nav.xhtml", category: "Converter")
            
            let ncxContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
                <docTitle><text>\(epubName)</text></docTitle>
                <navMap>
                    <navPoint id="navPoint-1" playOrder="1">
                        <navLabel><text>Start</text></navLabel>
                        <content src="text/page_0001.xhtml"/>
                    </navPoint>
                </navMap>
            </ncx>
            """
            try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: String.Encoding.utf8)
            Logger.shared.log("✅ Wrote toc.ncx", category: "Converter")
            
            // Process Items in this Batch
            let chunkSize = 20
            var currentChunkImages: [String] = []
            var chunkIndex = 0
            
            // Phase 4: Split Volume Cover Retention
            if batchIndex > 0, let coverData = firstBatchCoverData {
                let coverName = "cover_reused.jpg"
                let coverURL = imagesDir.appendingPathComponent(coverName)
                try? coverData.write(to: coverURL)
                
                manifestItems.append("<item id=\"cover_reused_img\" href=\"images/\(coverName)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
                currentChunkImages.append(coverName)
            }
            
            for (localIndex, item) in batch.enumerated() {
                let trueExt = (item.url.pathExtension.lowercased() == "png") ? "png" : "jpg"
                let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
                
                // Save Image
                let newImageName = String(format: "image_%04d.%@", localIndex + 1, trueExt)
                let destURL = imagesDir.appendingPathComponent(newImageName)
                try item.data.write(to: destURL)
                
                if !hasCapturedResolution {
                    if let image = UIImage(data: item.data) {
                        contentSize = image.size
                        hasCapturedResolution = true
                        if batchIndex == 0 && localIndex == 0 {
                            firstBatchCoverData = item.data
                        }
                    }
                }
                
                let properties = (localIndex == 0 && batchIndex == 0) ? "properties=\"cover-image\"" : ""
                manifestItems.append("<item id=\"img_\(localIndex+1)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\" \(properties)/>")
                
                currentChunkImages.append(newImageName)
                
                // If chunk is full or this is the last item, write the chunk XHTML
                if currentChunkImages.count >= chunkSize || localIndex == batch.count - 1 {
                    chunkIndex += 1
                    let chunkXHTML = CBZToEPUBConverter.generateChunkXHTML(
                        chunkIndex: chunkIndex,
                        images: currentChunkImages,
                        title: "Part \(chunkIndex)"
                    )
                    let chunkName = String(format: "chunk_%04d.xhtml", chunkIndex)
                    try chunkXHTML.write(to: textDir.appendingPathComponent(chunkName), atomically: true, encoding: .utf8)
                    
                    manifestItems.append("<item id=\"chunk_\(chunkIndex)\" href=\"text/\(chunkName)\" media-type=\"application/xhtml+xml\"/>")
                    spineItems.append("<itemref idref=\"chunk_\(chunkIndex)\"/>")
                    
                    currentChunkImages.removeAll()
                }
            }
            
            // OPF Generation
            // We use standard Reflowable Layout
            let opfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                    <dc:title>\(epubName.xmlEscaped())</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                    <meta property="rendition:spread">landscape</meta>
                    <meta name="cover" content="\(batchIndex > 0 && firstBatchCoverData != nil ? "cover_reused_img" : "img_1")"/>
                </metadata>
                <manifest>
                    \(manifestItems.joined(separator: "\n        "))
                </manifest>
                <spine toc="ncx" page-progression-direction="\(settings.mangaMode ? "rtl" : "ltr")">
                    \(spineItems.joined(separator: "\n        "))
                </spine>
            </package>
            """
            
            try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: String.Encoding.utf8)

            
            // Zip
            // ✅ Sanitize Filename (User Preference: Spaces over Underscores)
            // Replace underscores with spaces, allow natural spaces, remove special chars.
            let safeName = epubName.map { char -> String in
                if char.isLetter || char.isNumber || char == "-" {
                    return String(char)
                } else if char == "_" || char.isWhitespace {
                    return " "
                } else {
                    return ""
                }
            }.joined()
            
            let outputFilename = (safeName.isEmpty ? "comic" : safeName) + ".epub"
            let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
            if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
            
            // ✅ FIX: Manual Zipping to ensure mimetype is UNCOMPRESSED and FIRST
            // Wrapped in DO block to ensure Archive deinit (and close) before we try to read it
            try {
                guard let archive = Archive(url: outputURL, accessMode: .create) else {
                    throw NSError(domain: "Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create EPUB archive"])
                }
                
                // 1. Add mimetype (STORED, No Compression, No Extra Fields)
                let mimetypePath = batchDir.appendingPathComponent("mimetype")
                try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
                // Using fileURL-based addEntry avoids explicit metadata passed in closure, helping avoid extra fields
                try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
                
                // 2. Add META-INF/container.xml (Strictly Second)
                let containerPath = metaInfDir.appendingPathComponent("container.xml")
                try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .deflate)
                
                // 3. Add OEBPS Content recursively
                let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: nil)!
                while let fileURL = enumerator.nextObject() as? URL {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                    if resourceValues.isDirectory == true { continue }
                    
                    // Relative path in archive (e.g., "OEBPS/content.opf", "OEBPS/images/img_1.jpg")
                    // We need to construct the path relative to 'batchDir'
                    if let relativePath = fileURL.path.components(separatedBy: "\(batchDir.path)/").last {
                        try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                    }
                }
            }() // End scope to close file
            
            generatedFiles.append(outputURL)
            
            // ✅ DEBUG: Log Structure immediately for verification
            Logger.shared.log("About to analyze EPUB structure for: \(outputURL.lastPathComponent)", category: "Debug")
            Logger.shared.logEPUBStructure(at: outputURL)
            
            progress(0.5 + (0.5 * Double(batchIndex + 1) / Double(batches.count)))
        }
        
        progress(1.0)
        return generatedFiles
    }
    
    static func generateChunkXHTML(chunkIndex: Int, images: [String], title: String) -> String {
        let imageElements = images.enumerated().map { i, imageName in
            """
                <div class="page">
                    <img src="../images/\(imageName)" class="page-image" alt="Page Image"/>
                </div>
            """
        }.joined(separator: "\n")
        
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta charset="UTF-8"/>
    <title>\(title)</title>
    <style>
        /* Native Reflowable Layout for Columns */
        @page {
            margin: 0;
            padding: 0;
        }
        @media amzn-kf8 {
            body { margin: 0 !important; padding: 0 !important; }
        }
        html, body { 
            margin: 0; 
            padding: 0; 
            background-color: #000000; 
        }
        .chunk-container {
            width: 100%;
            column-gap: 0;
            -webkit-column-gap: 0;
        }
        .page { 
            text-align: center;
            page-break-inside: avoid;
            margin: 0; 
            padding: 0; 
        }
        .page-image {
            max-width: 100%;
            max-height: 100vh;
            height: auto;
            object-fit: contain;
        }
    </style>
</head>
<body>
    <div class="chunk-container">
    \(imageElements)
    </div>
</body>
</html>
"""
    }
    
    // MARK: - Helpers
    private func resizeImage(_ image: UIImage, targetSize: CGSize?) -> UIImage {
        guard let target = targetSize else { return image }
        
        // Use CGImage dimensions
        let width = image.cgImage?.width ?? Int(image.size.width)
        let height = image.cgImage?.height ?? Int(image.size.height)
        let currentSize = CGSize(width: width, height: height)
        
        // Only Downscale
        if currentSize.width <= target.width && currentSize.height <= target.height { return image }
        
        let widthRatio = target.width / currentSize.width
        let heightRatio = target.height / currentSize.height
        let scale = min(widthRatio, heightRatio)
        
        let newSize = CGSize(width: currentSize.width * scale, height: currentSize.height * scale)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

