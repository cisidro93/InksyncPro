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
            // ✅ Inject ComicInfo.xml for App Round-Trip Persistence
            // This ensures that if the user opens this EPUB in Inksync, the panels are restored.
            var batchPanels: [Int: [PanelExtractor.Panel]] = [:]
            for (localIndex, item) in batch.enumerated() {
                let pagePanels = manualManifest?[item.index] ?? [] // Ensure we use the resolved panels
                if !pagePanels.isEmpty {
                    batchPanels[localIndex] = pagePanels
                }
            }
            
            if !batchPanels.isEmpty {
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
                try? xml.write(to: batchDir.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)
            }
            
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
    
    private func generateXHTML(imageName: String, title: String, panels: [PanelExtractor.Panel]) -> String {
        var panelDivs = ""
        var targetDivs = ""
        
        if !panels.isEmpty {
            for (i, panel) in panels.enumerated() {
                let ord = i + 1
                
                // Coordinate-Based Region Magnification (Matches EPUBGenerator)
                // Coordinates are Integers (Percentages 0-100).
                // 'panel.boundingBox' is Normalized Top-Left Origin.
                
                let minX = Int(panel.boundingBox.minX * 100)
                let minY = Int(panel.boundingBox.minY * 100)
                let maxX = Int(panel.boundingBox.maxX * 100)
                let maxY = Int(panel.boundingBox.maxY * 100)
                
                // Construct coordinate arrays [x, y]
                let ul = "[\(minX), \(minY)]"
                let ur = "[\(maxX), \(minY)]"
                let lr = "[\(maxX), \(maxY)]"
                let ll = "[\(minX), \(maxY)]"
                
                let jsonString = "{\"ord\":\(ord), \"parent\":\"img-container\", \"ul\":\(ul), \"ur\":\(ur), \"lr\":\(lr), \"ll\":\(ll)}"
                
                // Overlay Div
                let top = String(format: "%.2f", panel.boundingBox.minY * 100)
                let left = String(format: "%.2f", panel.boundingBox.minX * 100)
                let width = String(format: "%.2f", panel.boundingBox.width * 100)
                let height = String(format: "%.2f", panel.boundingBox.height * 100)
                
                panelDivs += """
                <div id="panel-\(ord)" class="app-amzn-magnify" 
                     style="position: absolute; top: \(top)%; left: \(left)%; width: \(width)%; height: \(height)%; z-index: 20; cursor: pointer;"
                     data-app-amzn-magnify='\(jsonString)'>
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
            <meta name="viewport" content="width=100%, height=100%"/>
            <style type="text/css">
                body { margin: 0; padding: 0; background-color: #000; height: 100vh; width: 100vw; overflow: hidden; }
                .page-container { position: relative; width: 100%; height: 100%; }
                img.bg { width: 100%; height: 100%; object-fit: contain; }
                
                /* Region Magnification */
                .app-amzn-magnify {
                    z-index: 10;
                    cursor: pointer;
                    background-color: rgba(0,0,0,0); /* Transparent */
                }
            </style>
        </head>
        <body>
            <div class="page-container" id="img-container">
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
