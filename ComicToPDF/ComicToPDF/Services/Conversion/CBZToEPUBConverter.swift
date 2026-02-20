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
        var firstBatchCoverData: Data? = nil // ✅ Phase 4: Store cover for splits
        
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
            
            // ✅ CSS GENERATION (Critical for Kindle Panel View)
            // This ensures the .app-amzn-magnify class has absolute positioning and z-index.
            let cssContent = """
            * { margin: 0; padding: 0; border: 0; }
            html, body {
                width: 100%;
                height: 100%;
                overflow: hidden;
                background-color: #000000;
            }
            .page {
                position: absolute;
                width: 100%;
                height: 100%;
                margin: 0;
                padding: 0;
            }
            .page-image {
                position: absolute;
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
            for (localIndex, item) in batch.enumerated() {
                let trueExt = (item.url.pathExtension.lowercased() == "png") ? "png" : "jpg"
                let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
                
                // Save Image
                let newImageName = String(format: "image_%04d.%@", localIndex + 1, trueExt)
                let destURL = imagesDir.appendingPathComponent(newImageName)
                try item.data.write(to: destURL)
                
                // ✅ CAPTURE RESOLUTION & COVER (Once)
                if !hasCapturedResolution {
                    if let image = UIImage(data: item.data) {
                        contentSize = image.size
                        hasCapturedResolution = true
                        
                        // Capture Cover Data for Split Volumes
                        if batchIndex == 0 && localIndex == 0 {
                            firstBatchCoverData = item.data
                        }
                    }
                }
                
                // Detect Panels (Global Index Lookup)
                var pagePanels = manualManifest?[item.index] ?? []
                // ✅ FIX: Ensure panels are detected for Guided View even if "Panel Split" (Physical Split) is off
                if pagePanels.isEmpty && (settings.enablePanelSplit || settings.isGuidedView) {
                    if let image = UIImage(data: item.data) {
                        pagePanels = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: settings.mangaMode)
                    }
                }
                
                // Get Dimensions for Viewport
                let imageSize = UIImage(data: item.data)?.size ?? CGSize(width: 1000, height: 1500)

                // Create XHTML
                // ✅ FIX: Use Global Index (item.index) for Page ID to ensure uniqueness across batches
                let globalPageNum = item.index + 1
                let xhtmlContent = CBZToEPUBConverter.generateXHTML(imageName: newImageName, title: "Page \(globalPageNum)", width: Int(imageSize.width), height: Int(imageSize.height), panels: pagePanels, pageIndex: globalPageNum)
                let xhtmlName = String(format: "page_%04d.xhtml", globalPageNum)
                try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
                
                // ✅ Phase 4: Split Volume Cover Retention
                // If this is Batch > 0 (Split Part) AND it's the first item, 
                // we want to inject the captured cover image as the TRUE first page.
                if batchIndex > 0 && localIndex == 0, let coverData = firstBatchCoverData {
                    // 1. Write Cover Image
                    let coverName = "cover_reused.jpg"
                    let coverURL = imagesDir.appendingPathComponent(coverName)
                    try? coverData.write(to: coverURL)
                    
                    // 2. Write Cover XHTML
                    // We use standard full-page cover layout
                    let coverWidth = Int(contentSize.width)
                    let coverHeight = Int(contentSize.height)
                    let coverXHTML = CBZToEPUBConverter.generateXHTML(imageName: coverName, title: "Cover", width: coverWidth, height: coverHeight, panels: [], pageIndex: 0)
                    let coverXHTMLName = "cover_reused.xhtml"
                    try? coverXHTML.write(to: textDir.appendingPathComponent(coverXHTMLName), atomically: true, encoding: .utf8)
                    
                    // 3. Add to Manifest (Top of list)
                    manifestItems.append("<item id=\"cover_reused_img\" href=\"images/\(coverName)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
                    manifestItems.append("<item id=\"cover_reused_page\" href=\"text/\(coverXHTMLName)\" media-type=\"application/xhtml+xml\"/>")
                    
                    // 4. Add to Spine (First item)
                    // No spread properties for cover usually, or center
                    spineItems.append("<itemref idref=\"cover_reused_page\" properties=\"page-spread-center\"/>")
                }

                // Manifest
                // If valid split cover was injected above, this page is no longer the "cover-image" property holder
                // But generally, the first item of a split file is just "Page 1 of Part 2".
                let properties = (localIndex == 0 && batchIndex == 0) ? "properties=\"cover-image\"" : ""
                manifestItems.append("<item id=\"img_\(localIndex+1)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\" \(properties)/>")
                manifestItems.append("<item id=\"page_\(localIndex+1)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>")
                
                // ✅ Page Spread Property
                // FIX: "isGuidedView" implies we want the device to handle panel zooming on a SINGLE canvas.
                // Forcing page-spread-* properties causes the Kindle to group pages into 2-page spreads, 
                // breaking the flow and panel-to-panel navigation.
                // We REMOVE spread properties for GuidedView to ensure a linear, single-page flow.
                var spreadProp = ""
                if !settings.isGuidedView {
                     // Only apply spread logic if NOT in Guided View mode
                     // (or if user explicitly wanted spreads, but current issue is 2x2 forcing)
                     if item.index == 0 {
                         spreadProp = "page-spread-center"
                     } else {
                         let isOdd = (item.index % 2 != 0)
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
            
            // OPF Generation
            // (Identifiers are already defined at top of scope)
            
            // ✅ SURGICAL FIX: Proper Viewport for Kindle
            // Set viewport to Kindle Scribe/Colorsoft dimensions (1860x2480 at 300ppi)
            // This ensures the EPUB canvas matches Kindle's actual screen, eliminating gray bars
            // while preserving full image content (no cropping)
            let kindleWidth = 1860
            let kindleHeight = 2480
            
            // ✅ DYNAMIC ORIENTATION (Fixes "Locked Landscape" on Portrait Comics)
            // If the content is taller than it is wide, we must tell Kindle it's a Portrait book.
            // Otherwise, it forces landscape mode and letterboxes the portrait pages.
            let isPortrait = heightID > widthID
            let orientation = isPortrait ? "portrait" : "landscape"
            
            // "landscape" spread mode allows 2-page spreads when the device is in landscape,
            // but doesn't force the device INTO landscape if the book is portrait.
            let spreadMode = "landscape" 
            
            let writingMode = settings.mangaMode ? "horizontal-rl" : "horizontal-lr"
            
            let fixedLayoutMetadata = """
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:orientation">\(orientation)</meta>
                    <meta property="rendition:spread">\(spreadMode)</meta>
                    <meta name="fixed-layout" content="true"/>
                    <meta name="RegionMagnification" content="true"/>
                    <meta name="original-resolution" content="\(widthID)x\(heightID)"/>
                    <meta name="book-type" content="comic"/>
                    <meta name="primary-writing-mode" content="\(writingMode)"/>
                    <meta name="orientation-lock" content="none"/>
"""
            
            var opfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                    <dc:title>\(epubName.xmlEscaped())</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                    \(fixedLayoutMetadata)
                    <meta name="cover" content="img_1"/>
                </metadata>
                <manifest>
                    \(manifestItems.joined(separator: "\n        "))
                </manifest>
                <spine toc="ncx" page-progression-direction="\(settings.mangaMode ? "rtl" : "ltr")">
                    \(spineItems.joined(separator: "\n        "))
                </spine>
            </package>
            """
            
            // ✅ Inject ComicInfo.xml...
            // (Only injected if panels exist)
            
            // ... (Rest of OPF writing)

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
    
    static func generateXHTML(imageName: String, title: String, width: Int, height: Int, panels: [PanelExtractor.Panel], pageIndex: Int) -> String {
        // ✅ STRATEGY: Hybrid ID-Based with CSS Background Cropping
        // 1. KDP Docs say "Target div is displayed". If it's empty, you see nothing.
        // 2. Coordinate-based (JSON only) failed in testing.
        // 3. Solution: Use ID-based, but FILL the target div with the panel image using CSS.
        //    We use background-image with calculated position/size to show JUST the panel region.
        
        var panelOverlays = ""
        
        if !panels.isEmpty {
            for (index, panel) in panels.enumerated() {
                // 1. Geometry - Flip Y (Vision Origin Bottom-Left -> Top-Left)
                let normY = 1.0 - panel.boundingBox.maxY
                
                // 2. Scale to Image Size (No Offset) & CLAMP
                let rawPX = (panel.boundingBox.minX * Double(width))
                let rawPY = (normY * Double(height))
                let rawPW = (panel.boundingBox.width * Double(width))
                let rawPH = (panel.boundingBox.height * Double(height))
                
                let pX = max(0, min(Double(width), rawPX))
                let pY = max(0, min(Double(height), rawPY))
                let pW = min(Double(width) - pX, rawPW)
                let pH = min(Double(height) - pY, rawPH)
                
                if pW < 5 || pH < 5 { continue }
                
                // 3. CSS Percentages for Placement (Outer Divs)
                let pctX = String(format: "%.3f%%", (pX / Double(width)) * 100.0)
                let pctY = String(format: "%.3f%%", (pY / Double(height)) * 100.0)
                let pctW = String(format: "%.3f%%", (pW / Double(width)) * 100.0)
                let pctH = String(format: "%.3f%%", (pH / Double(height)) * 100.0)
                
                // 4. Background Image Calculation (The "Crop")
                // To show just the panel region in the target div:
                // background-size: Ratio of Page / Panel. (e.g. if Panel is 50% width, BG is 200% width)
                // background-position: Ratio of X / (Page - Panel). Complex CSS math.
                // EASIER: Use simple percentages relative to the DIV.
                
                // bgWidth% = (PageWidth / PanelWidth) * 100
                // bgHeight% = (PageHeight / PanelHeight) * 100
                let bgW = (Double(width) / pW) * 100.0
                let bgH = (Double(height) / pH) * 100.0
                
                // bgPosX% = (pX / (PageWidth - PanelWidth)) * 100
                // This is how CSS background-position percentages work (aligning edges).
                // Formula: pos% = (offset / (container - object)) * 100? No.
                // Standard CSS background-position: 0% = Left align, 100% = Right align.
                // If we want to align the image such that pX is at 0...
                // Actually, let's use PIXELS for background-position to be safe and precise, 
                // but percentages for size/layout.
                // Wait, mixed units might be tricky. Let's try standard CSS Sprite logic.
                // position: absolute; ...
                // background-position: -pX -pY
                // BUT background-size must be the PAGE size.
                // We can't use pixels easily because the device scales the page.
                
                // Re-calculating for Responsive CSS:
                // background-size: (PageWidth / PanelWidth) * 100 % (Relative to Target Div)
                // background-position:
                //   X: (pX / (PageWidth - PanelWidth)) * 100 % ??? No.
                //   Let's use the explicit formulas:
                //   bpX = - (pX / pW) * 100 % (Relative to Target Width) ? No.
                //   Let's use a simpler trick: Inner Image.
                //   Using background-image is cleaner if we get the math right.
                //   Correct Math for background-position in %: 
                //   pos% = ( x / (container_width - image_width) ) ... NO, that's for alignment.
                //   We want to shift.
                //   Let's stick to the simplest robust way:
                //   Target Div (overflow:hidden) -> Inner Img (position:absolute).
                //   Inner Img Width = (PageWidth / PanelWidth) * 100 %
                //   Inner Img Left = -(pX / pW) * 100 %
                
                let imgW_pct = (Double(width) / pW) * 100.0
                let imgH_pct = (Double(height) / pH) * 100.0
                let imgL_pct = -(pX / pW) * 100.0
                let imgT_pct = -(pY / pH) * 100.0
                
                let innerImgStyle = String(format: "position:absolute; width:%.3f%%; height:%.3f%%; top:%.3f%%; left:%.3f%%; max-width:none; max-height:none;", imgW_pct, imgH_pct, imgT_pct, imgL_pct)
                
                // 5. Metadata
                let targetId = "p\(pageIndex)-panel\(index + 1)-t"
                let sourceId = "p\(pageIndex)-panel\(index + 1)-s"
                let magnifyData = "{\"targetId\":\"\(targetId)\",\"sourceId\":\"\(sourceId)\",\"ordinal\":\(index + 1)}"

                // 6. Output HTML
                // Source: Transparent Overlay
                panelOverlays += """
                <a class="app-amzn-magnify" data-app-amzn-magnify='\(magnifyData)' style="display:block; position:absolute; top:\(pctY); left:\(pctX); width:\(pctW); height:\(pctH); z-index:10;">
                    <div id="\(sourceId)" class="panel-source" style="width:100%; height:100%;"></div>
                </a>
                
                <div id="\(targetId)" class="panel-target" style="overflow:hidden; position:absolute; top:\(pctY); left:\(pctX); width:\(pctW); height:\(pctH); z-index:5;">
                    <img src="../images/\(imageName)" style="\(innerImgStyle)" alt="zoomed panel" />
                </div>
"""
            }
        }
        
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=\(width), height=\(height)"/>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
    <style>
        body { margin: 0; padding: 0; background-color: black; }
        .page-container { position: relative; width: \(width)px; height: \(height)px; margin: 0 auto; }
        img.bg {
            width: 100%;
            height: 100%;
            object-fit: contain;
            display: block;
        }
        .app-amzn-magnify { border: 0; background-color: transparent; -webkit-tap-highlight-color: rgba(0,0,0,0); }
    </style>
</head>
<body>
    <div class="page-container">
        <!-- Background Image -->
        <img src="../images/\(imageName)" class="bg" alt="comic page"/>
             
        <!-- Guided View Overlays (Hybrid ID-Based with Content) -->
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

