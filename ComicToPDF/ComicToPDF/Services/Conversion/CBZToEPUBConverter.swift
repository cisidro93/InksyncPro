import SwiftUI
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]?, progress: @escaping (Double) -> Void) async throws -> [URL] {
        
        let fileManager = FileManager.default
        let baseFilename = sourceURL.deletingPathExtension().lastPathComponent
        
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
                // Copy Original
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
                print("⚠️ Auto-Splitting at \(currentBatchSize) bytes (Image: \(index))")
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
                
                // Create XHTML
                let xhtmlContent = generateXHTML(imageName: newImageName, title: "Page \(localIndex + 1)", panels: pagePanels)
                let xhtmlName = String(format: "page_%04d.xhtml", localIndex + 1)
                try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
                
                // Manifest
                let properties = (localIndex == 0) ? "properties=\"cover-image\"" : ""
                manifestItems.append("<item id=\"img_\(localIndex+1)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\" \(properties)/>")
                manifestItems.append("<item id=\"page_\(localIndex+1)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\" properties=\"svg\"/>")
                spineItems.append("<itemref idref=\"page_\(localIndex+1)\"/>")
            }
            
            // OPF & TOC
            let widthID = Int(contentSize.width)
            let heightID = Int(contentSize.height)
            
            let opfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>\(epubName)</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:orientation">auto</meta>
                    <meta property="rendition:spread">auto</meta>
                    <meta name="fixed-layout" content="true"/>
                    <meta name="original-resolution" content="\(widthID)x\(heightID)"/> 
                    <meta name="book-type" content="comic"/>
                    <meta name="region-mag" content="true"/>
                    <meta name="cover" content="img_1"/>
                </metadata>
                <manifest>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    \(manifestItems.joined(separator: "\n        "))
                </manifest>
                <spine toc="ncx">
                    \(spineItems.joined(separator: "\n        "))
                </spine>
            </package>
            """
            try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
            
            let ncxContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                <head><meta name="dtb:uid" content="urn:uuid:12345"/></head>
                <docTitle><text>\(epubName)</text></docTitle>
                <navMap>
                    <navPoint id="navPoint-1" playOrder="1">
                        <navLabel><text>Start</text></navLabel>
                        <content src="text/page_0001.xhtml"/>
                    </navPoint>
                </navMap>
            </ncx>
            """
            try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
            
            // Zip
            let outputFilename = epubName + ".epub"
            let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
            if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
            
            try fileManager.zipItem(at: batchDir, to: outputURL, compressionMethod: .deflate)
            generatedFiles.append(outputURL)
        
            
            progress(0.5 + (0.5 * Double(batchIndex + 1) / Double(batches.count)))
        }
        
        progress(1.0)
        return generatedFiles
    }
    
    // ✅ OPTION B IMPLEMENTATION: CSS-Based Region Magnification
    private func generateXHTML(imageName: String, title: String, panels: [PanelExtractor.Panel]) -> String {
        
        // 1. Generate Source (Hit Area) and Target (Zoom View) Divs for each Panel
        var panelDivs = ""
        var targetDivs = ""
        
        if !panels.isEmpty {
            for (i, panel) in panels.enumerated() {
                // Convert 0.0-1.0 coords to percentages for the Source Div (Hit Area)
                let top = String(format: "%.2f", panel.boundingBox.minY * 100)
                let left = String(format: "%.2f", panel.boundingBox.minX * 100)
                let width = String(format: "%.2f", panel.boundingBox.width * 100)
                let height = String(format: "%.2f", panel.boundingBox.height * 100)
                
                let ord = i + 1
                
                // A. Source Div (The Invisible Button)
                panelDivs += """
                <div id="panel-\(ord)" class="app-amzn-magnify" data-app-amzn-magnify="{
                    \\"targetId\\": \\"panel-target-\(ord)\\",
                    \\"ordinal\\": \(ord)
                }" style="position: absolute; top: \(top)%; left: \(left)%; width: \(width)%; height: \(height)%;">
                </div>
                """
                
                // B. Target Div (The Zoomed View)
                // We recreate the image but "position" it so only the panel is visible.
                // This is a CSS Trick: The container is the size of the panel, but scaled up to fill the screen?
                // Actually, for Kindle Region Magnification, the Target is usually just a replacement view.
                // To keep it simple and efficient: We just provide a div that contains the image focused on that area.
                // However, Kindle's default behavior with just a targetId is to Zoom that TargetId to fit the screen.
                
                // We use a container with overflow:hidden to "crop" the image visually for the target
                // Logic:
                // 1. Target Container: 100% width/height of the viewport (or close to it)
                // 2. Image inside: Scaled and Positioned so the panel fills the Target Container.
                
                // MATH:
                // If Panel Width is 50% (0.5), we need to scale the image by 2x (1/0.5).
                // If Panel Left is 10% (0.1), we need to move the image Left by -10% * Scale.
                
                let pW = panel.boundingBox.width
                let pH = panel.boundingBox.height
                let pX = panel.boundingBox.minX
                let pY = panel.boundingBox.minY
                
                // Scale factor to make the panel fill the screen logic (fit to aspect ratio)
                // Simplification for v1: We just crop. Kindle engine handles the "Zoom to fit screen" of the target div.
                // So we just describe the panel as a standalone div.
                
                // To display *just* the panel using the full page image:
                // Container: Width = PanelWidth%, Height = PanelHeight%
                // Image: Width = 100% / PanelWidth, Height = 100% / PanelHeight ?? 
                // No, that's complex relative math.
                
                // Easier Approach: Absolute pixel coords if we knew them? No, we use %.
                
                // Let's use the 'mag-target' class to hide it by default.
                // We put the image inside, and we want to show ONLY the rect.
                // We can use clip-path if Kindle supports it (newer ones do).
                // converting CGRect (0..1) to inset %: top, right, bottom, left
                
                let insetTop = pY * 100
                let insetRight = (1.0 - (pX + pW)) * 100
                let insetBottom = (1.0 - (pY + pH)) * 100
                let insetLeft = pX * 100
                
                // Using standard CSS absolute positioning + overflow hidden to crop
                targetDivs += """
                <div id="panel-target-\(ord)" style="display:none;">
                    <div style="position: absolute; width: 100%; height: 100%; overflow: hidden;">
                         <img src="../images/\(imageName)" style="position: absolute; top: -\(insetTop)%; left: -\(insetLeft)%; width: 100%; height: 100%; transform: scale(\(1.0/pW), \(1.0/pH)); transform-origin: top left;" />
                    </div>
                </div>
                """
                
                // REVISION: The transform math above is tricky because 'top' is relative to... parent?
                // A safer, more robust way for Kindle (High Compat):
                // Just use the Source Div itself as the Target? No.
                
                // Let's rely on Kindle's automatic behavior if possible, but standard requires a target.
                // Correction: For standard "Region Magnification", specific CSS is often avoided to prevent breaking.
                // We will create a Target Div that contains the image, but we will NOT try to fancy crop it too hard.
                // Ideally, we'd use a separate cropped image (Physical Splitting), but we deleted that.
                
                // Compromise: We will generate the target div as a wrapper.
                // If we leave it empty or just the image, Kindle might just zoom the whole page again?
                // Actually, for "Virtual Panels", the best approach is:
                // Don't use a separate target. Point targetId to the SOURCE div, and let Kindle zoom to that bounding box.
                // Many implementations do: targetId == sourceId.
            }
            
            // RE-EVALUATION:
            // If I set targetId == panel-1 (the source div), Kindle will zoom into the element with id "panel-1".
            // Since "panel-1" has defined dimensions (top, left, width, height) and is positioned over the image...
            // It might just zoom into a transparent square.
            
            // However, if "panel-1" CONTAINS a clone of the image...
            // <div id="panel-1" ...> <img src="..." style="margin-top: -..."/> </div>
            // That works.
            
            // LET'S TRY THE SIMPLEST FIX:
            // Change the JSON to NOT use targetId if possible? No, strictly required.
            
            // GOING WITH: "Mag Target is a hidden div that has the image cropped/positioned".
            // But doing the CSS math properly in a string literal is risky.
            
            // NEW STRATEGY:
            // We'll stick to just the source divs for now but FIX the JSON to point to ITSELF?
            // "data-app-amzn-magnify": "{\"targetId\":\"panel-\(ord)\", \"ordinal\":\(ord)}"
            // If the target is itself, Kindle zooms to that element.
            // But that element is transparent.
            // So we need to put the image INSIDE the panel div, with coordinates shifted so the correct part shows.
            
            // Refactored Loop for "Self-Contained Panels"
            // This is the "Virtual Layout" method.
        }
        
        // RE-GENERATING PANELS TO BE SELF-CONTAINED
        panelDivs = "" // Reset
        
        if !panels.isEmpty {
            for (i, panel) in panels.enumerated() {
                let ord = i + 1
                
                // 1. Dimensions of the Panel (Window)
                let top = panel.boundingBox.minY * 100
                let left = panel.boundingBox.minX * 100
                let width = panel.boundingBox.width * 100
                let height = panel.boundingBox.height * 100
                
                // 2. Dimensions of the Image relative to the Panel
                // Image needs to be scaled up. 
                // ScaleX = 100 / Width
                // ScaleY = 100 / Height
                // PositionX = -Left * ScaleX
                // PositionY = -Top * ScaleY
                
                let scaleX = 100.0 / (panel.boundingBox.width)
                let scaleY = 100.0 / (panel.boundingBox.height)
                
                // We use 'left' percentage for position relative to the CONTAINER (Panel Div)
                let imgLeft = -(panel.boundingBox.minX) * scaleX
                let imgTop = -(panel.boundingBox.minY) * scaleY
                
                panelDivs += """
                <div id="panel-\(ord)" class="app-amzn-magnify" data-app-amzn-magnify='{
                    "targetId": "panel-\(ord)",
                    "ordinal": \(ord)
                }' style="position: absolute; top: \(String(format: "%.2f", top))%; left: \(String(format: "%.2f", left))%; width: \(String(format: "%.2f", width))%; height: \(String(format: "%.2f", height))%; overflow: hidden; display: block;">
                    <img src="../images/\(imageName)" style="position: absolute; top: \(String(format: "%.2f", imgTop))%; left: \(String(format: "%.2f", imgLeft))%; width: \(String(format: "%.2f", scaleX))%; height: \(String(format: "%.2f", scaleY))%; max-width: none; max-height: none;" />
                </div>
                """
            }
        }
        
        // Wrapper remains the same
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
            <title>\(title)</title>
            <meta name="viewport" content="width=100%, height=100%"/>
            <style type="text/css">
                body { margin: 0; padding: 0; background-color: #000; overflow: hidden; }
                .page-container { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
                img.bg { width: 100%; height: 100%; object-fit: contain; z-index: 1; }
                /* Panels sit on top (z-index 10), transparent by default? No, we need them to match the BG. */
                /* Actually, if we use the "Self Contained" method, the panels ARE visible chunks of the image floating on top. */
                /* Visually this looks identical to the base image if lined up perfectly. */
                /* Kindle will Hide/Show or Zoom to them as needed. */
                
                .app-amzn-magnify { 
                    z-index: 20; 
                    cursor: pointer;
                    opacity: 0; /* Hide by default so we see the base image */
                }
                
                /* When active/magnified, Kindle usually handles the visibility */
            </style>
        </head>
        <body>
            <div class="page-container">
                <img class="bg" src="../images/\(imageName)" alt="comic page"/>
                \(panelDivs)
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
