import SwiftUI
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]?, progress: @escaping (Double) -> Void) async throws -> [URL] {
        Logger.shared.log("Starting Conversion. Manual Manifest: \(manualManifest?.count ?? 0) pages", category: "Converter")
        
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
            
            // Only re-compress if we are NOT in High quality (preserve originals)
            // OR if the user wants splitting (to account for strict sizing)
            // But user specifically said "Compact" didn't work. So for Compact/Balanced we MUST re-compress.
            let needsCompression = settings.compressionQuality != .high
            
            var targetSize: CGSize? = nil
            if settings.optimizeForDevice {
                targetSize = settings.targetDevice.resolution
            } else if settings.compressionQuality == .compact {
                // If Compact is chosen but no specific device, default to a reasonable max (e.g. HD 1080p equivalent)
                targetSize = CGSize(width: 1440, height: 1920) 
            }
            
            if needsCompression, let image = UIImage(contentsOfFile: srcURL.path) {
                // 1. Resize (Downscale Only)
                let resizedImage = resizeImage(image, targetSize: targetSize)
                
                // 2. Re-encode
                finalData = resizedImage.jpegData(compressionQuality: settings.compressionQuality.value) ?? (try? Data(contentsOf: srcURL)) ?? Data()
            } else {
                // Check if format is safe for Kindle (JPEG/PNG only)
                // If it's WEBP, HEIC, etc., we MUST re-encode even if "Original Quality" is selected.
                let ext = srcURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png"].contains(ext) {
                     // Safe to copy original
                     finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                } else {
                     // Unsafe format (e.g. WebP), force convert to JPEG
                     if let image = UIImage(contentsOfFile: srcURL.path),
                        let jpegData = image.jpegData(compressionQuality: 0.9) {
                         finalData = jpegData
                     } else {
                         // Fallback (risk of failure, but better than crash)
                         finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                     }
                }
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
            let metaInfDir = batchDir.appendingPathComponent("META-INF")
            
            try? fileManager.removeItem(at: batchDir)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
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
            
            var spineItems: [String] = []
            var manifestItems: [String] = []
            
            // Process Items in this Batch
            for (localIndex, item) in batch.enumerated() {
                let ext = "jpg"
                let trueExt = (item.url.pathExtension.lowercased() == "png") ? "png" : "jpg"
                let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
                
                // Save Image
                let newImageName = String(format: "image_%04d.%@", localIndex + 1, trueExt)
                let destURL = imagesDir.appendingPathComponent(newImageName)
                try item.data.write(to: destURL)
                
                // ✅ CAPTURE RESOLUTION (Once)
                if !hasCapturedResolution {
                    if let image = UIImage(data: item.data) {
                        contentSize = image.size
                        hasCapturedResolution = true
                    }
                }
                
                // Detect Panels (Global Index Lookup)
                var pagePanels = manualManifest?[item.index] ?? []
                if pagePanels.isEmpty && settings.enablePanelSplit {
                    if let image = UIImage(data: item.data) {
                        pagePanels = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: settings.mangaMode)
                    }
                }
                
                // Get Dimensions for Viewport
                let imageSize = UIImage(data: item.data)?.size ?? CGSize(width: 1000, height: 1500)
                let PageWidth = Int(imageSize.width)
                let PageHeight = Int(imageSize.height)

                // Create XHTML
                let xhtmlContent = CBZToEPUBConverter.generateXHTML(imageName: newImageName, title: "Page \(localIndex + 1)", width: PageWidth, height: PageHeight, panels: pagePanels)
                let xhtmlName = String(format: "page_%04d.xhtml", localIndex + 1)
                try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
                
                // Manifest
                let properties = (localIndex == 0) ? "properties=\"cover-image\"" : ""
                manifestItems.append("<item id=\"img_\(localIndex+1)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\" \(properties)/>")
                manifestItems.append("<item id=\"page_\(localIndex+1)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>")
                
                // ✅ Page Spread Property (Only for Guided View / Fixed-Layout)
                // Standard EPUBs should NOT use page-spread as it forces landscape 2-page views
                // which confuses Kindle's page counter (30 pages -> 17 "spreads")
                var spreadProp = ""
                if settings.isGuidedView {
                    if item.index == 0 {
                        spreadProp = "page-spread-center"
                    } else {
                        let isOdd = (item.index % 2 != 0)
                        // LTR: Odd index (Page 2) = Left, Even index (Page 3) = Right
                        // RTL: Odd index (Page 2) = Right, Even index (Page 3) = Left
                        if settings.mangaMode {
                             spreadProp = isOdd ? "page-spread-right" : "page-spread-left"
                        } else {
                             spreadProp = isOdd ? "page-spread-left" : "page-spread-right"
                        }
                    }
                }
                
                let spreadAttr = spreadProp.isEmpty ? "" : " properties=\"\(spreadProp)\""
                spineItems.append("<itemref idref=\"page_\(localIndex+1)\"\(spreadAttr)/>")

            }
            
            // OPF & TOC
            let widthID = Int(contentSize.width)
            let heightID = Int(contentSize.height)
            let bookUUID = UUID().uuidString
            
            // ✅ SURGICAL FIX: Proper Viewport for Kindle
            // Set viewport to Kindle Scribe/Colorsoft dimensions (1860x2480 at 300ppi)
            // This ensures the EPUB canvas matches Kindle's actual screen, eliminating gray bars
            // while preserving full image content (no cropping)
            let kindleWidth = 1860
            let kindleHeight = 2480
            
            let fixedLayoutMetadata = settings.isGuidedView ? """
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:orientation">auto</meta>
                    <meta property="rendition:spread">none</meta> 
                    <meta name="fixed-layout" content="true"/>
                    <meta name="original-resolution" content="1000x1000"/> 
                    <meta name="book-type" content="comic"/> 
                    <meta name="primary-writing-mode" content="horizontal-lr"/>
""" : """
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:spread">none</meta>
                    <meta name="original-resolution" content="1000x1000"/> 
                    <meta name="book-type" content="comic"/> 
"""
            
            var opfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                    <dc:title>\(epubName.xmlEscaped())</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                    \(fixedLayoutMetadata)
                    <meta name="cover" content="img_1"/>
                    \(settings.mangaMode ? "<meta name=\"primary-writing-mode\" content=\"horizontal-rl\"/>" : "")
                </metadata>
                <manifest>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    \(manifestItems.joined(separator: "\n        "))
                </manifest>
                <spine toc="ncx" page-progression-direction="\(settings.mangaMode ? "rtl" : "ltr")">
                    \(spineItems.joined(separator: "\n        "))
                </spine>
            </package>
            """
            // try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8) // Removed redundant write
            
            // ✅ FIX: Generate EPUB 3.0 Navigation Document (Mandatory)
            // Added DOCTYPE for strict validation (E013 fix candidate)
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
            try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
            
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
            // ✅ Inject ComicInfo.xml for App Round-Trip Persistence
            // This ensures that if the user opens this EPUB in Inksync, the panels are restored.
            var batchPanels: [Int: [PanelExtractor.Panel]] = [:]
            for (localIndex, item) in batch.enumerated() {
                let pagePanels = manualManifest?[item.index] ?? [] 
                if !pagePanels.isEmpty {
                    batchPanels[localIndex] = pagePanels
                }
            }
            
            if !batchPanels.isEmpty {
                Logger.shared.log("Batch \(batchIndex): Writing ComicInfo.xml with \(batchPanels.count) pages", category: "Converter")
                var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo>\n  <Pages>\n"
                let sortedKeys = batchPanels.keys.sorted()
                for key in sortedKeys {
                    if let panels = batchPanels[key] {
                        xml += "    <Page Image=\"\(key)\">\n"
                        for panel in panels {
                            xml += "      <Panel x=\"\(panel.boundingBox.minX)\" y=\"\(panel.boundingBox.minY)\" width=\"\(panel.boundingBox.width)\" height=\"\(panel.boundingBox.height)\" />\n"
                        }
                        xml += "    </Page>\n"
                    }
                }
                xml += "  </Pages>\n</ComicInfo>"
                xml += "  </Pages>\n</ComicInfo>"
                
                // ✅ FIX: Embed ComicInfo as Base64 in OPF Metadata (Zero Footprint)
                // Kindle E013 rejects unmanifested files in META-INF or OEBPS.
                // We cannot manifest it because it's not a valid EPUB core media type.
                // Solution: Store the XML raw string as Base64 inside a <meta> tag in the OPF.
                // This is standard-compliant (custom metadata) and stays with the file.
                
                // 🕵️‍♂️ CONDITIONAL INJECTION (E013 FIX)
                // Only inject this massive blob if the user actually wants Guided View.
                // Standard conversions should be clean EPUBs.
                if settings.isGuidedView {
                    if let data = xml.data(using: .utf8) {
                        let base64 = data.base64EncodedString()
                        // Insert generic meta name tag (safest for Kindle)
                        // We avoid 'property' and custom namespaces to prevent E013 errors
                        if let range = opfContent.range(of: "</metadata>") {
                            let metaTag = "\n    <meta name=\"inksync-comicinfo\" content=\"\(base64)\"/>"
                            opfContent.insert(contentsOf: metaTag, at: range.lowerBound)
                        }
                    }
                } else {
                     Logger.shared.log("Skipping ComicInfo injection (Standard Mode)", category: "Converter")
                }
            } else {
                Logger.shared.log("Batch \(batchIndex): No panels to write", category: "Converter")
            }
            
            try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
            


            try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

            
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
                
                // 3. Add META-INF/ComicInfo.xml (REMOVED: Now embedded in OPF)
                // let comicInfoPath = metaInfDir.appendingPathComponent("ComicInfo.xml")
                // if fileManager.fileExists(atPath: comicInfoPath.path) {
                //    try archive.addEntry(with: "META-INF/ComicInfo.xml", fileURL: comicInfoPath, compressionMethod: .deflate)
                // }
                
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
    
    static func generateXHTML(imageName: String, title: String, width: Int, height: Int, panels: [PanelExtractor.Panel]) -> String {
        // ✅ STRATEGY: Viewport Matches Image Size (No Gray Bars)
        // We set the viewport to the exact image dimensions.
        // The device will scale this viewport to fit the screen, eliminating our manual letterboxing.
        // Panels map 1:1 to image coordinates.
        
        var panelOverlays = ""
        
        if !panels.isEmpty {
            for (index, panel) in panels.enumerated() {
                // Panels are 0-1 normalized (Vision/Bottom-Left)
                // We map directly to image dimensions (Top-Left)
                
                // 1. Flip Y (Vision -> Top-Left)
                let normY = 1.0 - panel.boundingBox.maxY
                
                // 2. Scale to Image Size (No Offset)
                let pX = (panel.boundingBox.minX * Double(width))
                let pY = (normY * Double(height))
                let pW = (panel.boundingBox.width * Double(width))
                let pH = (panel.boundingBox.height * Double(height))
                
                // 3. Metadata
                let targetId = "panel-target-\(index + 1)"
                let sourceId = "panel-source-\(index + 1)"
                
                // Amazon JSON Payload
                let magnifyData = """
{"targetId":"\(targetId)","sourceId":"\(sourceId)","ordinal":\(index + 1)}
"""
                // 4. Create Overlay Element (Transparent Tap Target)
                // 4. Create Overlay Element (Transparent Tap Target) AND Target Element (Zoom Area)
                // The Source controls the "Tap Area". The Target controls the "Zoom View".
                
                // Source (Tap Target)
                panelOverlays += """
                <a class="app-region-magnification" 
                   id="\(sourceId)"
                   data-amzn-magnification='\(magnifyData)'
                   style="position: absolute; left: \(String(format: "%.1f", pX))px; top: \(String(format: "%.1f", pY))px; width: \(String(format: "%.1f", pW))px; height: \(String(format: "%.1f", pH))px; z-index: 10;">
                </a>
"""
                // Target (Zoom Area) - Must match targetId
                panelOverlays += """
                <div id="\(targetId)"
                     style="position: absolute; left: \(String(format: "%.1f", pX))px; top: \(String(format: "%.1f", pY))px; width: \(String(format: "%.1f", pW))px; height: \(String(format: "%.1f", pH))px; z-index: 5; pointer-events: none;">
                </div>
"""
            }
        }
        
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <title>\(title)</title>
    <meta name="viewport" content="width=\(width), height=\(height)"/>
    <style type="text/css">
        html, body {
            margin: 0;
            padding: 0;
            width: 100%;
            height: 100%;
            background-color: #000000; /* Force black background to hide letterboxing */
        }
        .page-container {
            width: 100%;
            height: 100%;
            position: relative;
        }
        img.bg {
            width: 100%;
            height: 100%;
            object-fit: contain; /* Ensure proper scaling */
            display: block;
        }
        /* Panels are positioned absolutely relative to page-container (which matches viewport/image size) */
        .app-region-magnification { border: 0; background-color: transparent; -webkit-tap-highlight-color: rgba(0,0,0,0); }
    </style>
</head>
<body>
    <div class="page-container">
        <!-- Background Image -->
        <img src="../images/\(imageName)" class="bg" alt="comic page"/>
             
        <!-- Guided View Overlays -->
        \(panelOverlays)
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

