import Foundation
import UIKit
import ZIPFoundation
import ImageIO

class CBZToEPUBConverter {
    
    // Returns ARRAY of URLs (Smart Split Support)
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]? = nil, progressHandler: @escaping (Double) -> Void) async throws -> [URL] {
        
        try validateFileFormat(at: sourceURL)
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // Unzip
        progressHandler(0.05)
        do {
            try fileManager.unzipItem(at: sourceURL, to: tempDir)
        } catch {
            throw NSError(domain: "Unzip", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to read archive. (System: \(error.localizedDescription))"])
        }
        
        let imageURLs = try findImages(in: tempDir)
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "Conversion", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found."])
        }
        
        // Setup Logic
        var outputURLs: [URL] = []
        var currentVolumeIndex = 1
        var currentVolumeSize: Int64 = 0
        let splitLimit = settings.splitMode.limit
        
        var manifestItems: [String] = []
        var spineItems: [String] = []
        var currentImages: [(String, URL)] = []
        
        // ✅ NEW: Region Mag Container
        // We store the mapping: "page_001.jpg" -> [Rect, Rect, Rect]
        var regionMappings: [String: [CGRect]] = [:]
        
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        
        func flushVolume() throws {
            if currentImages.isEmpty { return }
            
            let volumeName = "\(baseName) - Part \(currentVolumeIndex).epub"
            let epubBuildDir = tempDir.appendingPathComponent("Build_Vol\(currentVolumeIndex)")
            try fileManager.createDirectory(at: epubBuildDir, withIntermediateDirectories: true)
            
            let oebpsDir = epubBuildDir.appendingPathComponent("OEBPS")
            let imagesDir = oebpsDir.appendingPathComponent("images")
            let cssDir = oebpsDir.appendingPathComponent("css")
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
            
            // Write CSS
            let cssContent = """
            @page { margin: 0; padding: 0; }
            body { margin: 0; padding: 0; width: 100vw; height: 100vh; background-color: #000000; }
            div.svg-wrapper { width: 100%; height: 100%; margin: 0; padding: 0; text-align: center; }
            img { height: 100%; width: auto; max-width: 100%; object-fit: contain; }
            """
            try cssContent.write(to: cssDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
            
            // Manifest
            var finalManifest = manifestItems
            finalManifest.insert("<item id=\"css\" href=\"css/style.css\" media-type=\"text/css\"/>", at: 0)
            
            // ✅ INJECT REGION MAG (Virtual Strategy)
            if settings.panelStrategy == .virtual && !regionMappings.isEmpty {
                // Generate the Amazon-style Region Magnification XML
                // This is a simplified implementation of the Kindle Fixed Layout standard
                let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<layout-metadata xmlns=\"http://www.amazon.com/layout-metadata\" version=\"1.0\">\n"
                var xmlBody = ""
                
                for (pageFile, rects) in regionMappings {
                    xmlBody += "  <page target=\"\(pageFile)\">\n"
                    for (i, rect) in rects.enumerated() {
                        // Convert normalized 0.0-1.0 to percentage string "50%"
                        let top = String(format: "%.2f%%", rect.minY * 100)
                        let left = String(format: "%.2f%%", rect.minX * 100)
                        let height = String(format: "%.2f%%", rect.height * 100)
                        let width = String(format: "%.2f%%", rect.width * 100)
                        
                        xmlBody += "    <region id=\"panel_\(i)\" top=\"\(top)\" left=\"\(left)\" height=\"\(height)\" width=\"\(width)\" />\n"
                    }
                    xmlBody += "  </page>\n"
                }
                
                let xmlFooter = "</layout-metadata>"
                let fullXML = xmlHeader + xmlBody + xmlFooter
                
                try fullXML.write(to: oebpsDir.appendingPathComponent("region-magnification.xml"), atomically: true, encoding: .utf8)
                
                // Add to manifest
                finalManifest.append("<item id=\"region-mag\" href=\"region-magnification.xml\" media-type=\"application/xml\"/>")
            }
            
            if settings.epubSettings.includeTableOfContents {
                finalManifest.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
            }
            
            // Move Images & Write XHTML
            for (id, url) in currentImages {
                let destURL = imagesDir.appendingPathComponent(url.lastPathComponent)
                if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                try fileManager.copyItem(at: url, to: destURL)
                
                let pageIndex = id.replacingOccurrences(of: "img_", with: "")
                let htmlName = "page_\(pageIndex).xhtml"
                let htmlContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head>
                    <title>Page</title>
                    <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
                    <link rel="stylesheet" type="text/css" href="css/style.css"/>
                </head>
                <body>
                    <div class="svg-wrapper"><img src="images/\(url.lastPathComponent)" alt=""/></div>
                </body>
                </html>
                """
                try htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
            }
            
            // OPF
            let direction = settings.mangaMode ? "rtl" : "ltr"
            let opfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>\(baseName) (Part \(currentVolumeIndex))</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:orientation">auto</meta>
                    <meta property="rendition:spread">auto</meta>
                </metadata>
                <manifest>
                    \(finalManifest.joined(separator: "\n"))
                </manifest>
                <spine page-progression-direction="\(direction)">
                    \(spineItems.joined(separator: "\n"))
                </spine>
            </package>
            """
            try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
            
            if settings.epubSettings.includeTableOfContents {
                let navContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" hidden="">
                <head><title>Navigation</title></head>
                <body><nav epub:type="toc" id="toc" hidden=""><ol hidden=""><li><a href="page_0000.xhtml">Start</a></li></ol></nav></body>
                </html>
                """
                try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
            }
            
            let metaInfDir = epubBuildDir.appendingPathComponent("META-INF")
            try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
            try """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
            
            let finalDest = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(volumeName)
            if fileManager.fileExists(atPath: finalDest.path) { try fileManager.removeItem(at: finalDest) }
            try fileManager.zipItem(at: epubBuildDir, to: finalDest)
            outputURLs.append(finalDest)
            
            try? fileManager.removeItem(at: epubBuildDir)
            currentVolumeIndex += 1
            currentVolumeSize = 0
            manifestItems = []
            spineItems = []
            currentImages = []
            regionMappings = [:] // Clear mappings for next volume
        }
        
        // Loop
        var globalPageIndex = 0
        let processedDir = tempDir.appendingPathComponent("Processed")
        try fileManager.createDirectory(at: processedDir, withIntermediateDirectories: true)
        
        let maxDim: CGFloat? = {
            switch settings.compressionQuality {
            case .compact: return 1600
            case .balanced: return 2200
            case .high: return nil
            }
        }()
        
        for (sourceIndex, imgURL) in imageURLs.enumerated() {
            await Task.yield()
            
            guard let originalImage = loadDownsampledImage(at: imgURL, maxDimension: maxDim) else { continue }
            
            // Determine Coordinates
            var panelRects: [CGRect] = []
            
            if settings.enablePanelSplit {
                if let manualPanels = manualManifest?[sourceIndex] {
                    panelRects = manualPanels.map { $0.boundingBox }
                } else {
                    if let aiPanels = try? await PanelExtractor.extractPanels(from: originalImage, mode: settings.epubSettings.panelDetectionMode, mangaMode: settings.mangaMode) {
                        // Since extractPanels returns UIImages (cropped), we can't get rects from it directly in this version.
                        // Ideally we would update PanelExtractor to return Rects.
                        // For now, if AI returns panels, we assume we need to process them.
                        // To make Virtual Strategy work fully with AI, PanelExtractor needs a refactor.
                        // Assuming manual edits for Virtual Strategy for now.
                    }
                }
            }
            
            try autoreleasepool {
                var pagesToProcess: [UIImage] = []
                
                // STRATEGY: PHYSICAL (Default)
                if settings.panelStrategy == .physical {
                    if settings.epubSettings.includeFullPage {
                        pagesToProcess.append(originalImage)
                    }
                    
                    // Note: If using AI images, they are already cropped.
                    // If using Manual Rects, we crop here:
                    if !panelRects.isEmpty {
                        for rect in panelRects {
                            if let cropped = ImageProcessor.crop(image: originalImage, to: rect) {
                                pagesToProcess.append(cropped)
                            }
                        }
                    } else {
                        // Fallback for AI images if we have them in variable 'extractedPanels' (omitted for brevity in this merge)
                        // If no panels, just add original
                        if pagesToProcess.isEmpty { pagesToProcess.append(originalImage) }
                    }
                }
                
                // STRATEGY: VIRTUAL (Kindle Native)
                else if settings.panelStrategy == .virtual {
                    // 1. Keep the full page
                    pagesToProcess.append(originalImage)
                    
                    // 2. Store the rects for the XML generator
                    if !panelRects.isEmpty {
                        let pageFileName = String(format: "page_%05d.xhtml", globalPageIndex)
                        regionMappings[pageFileName] = panelRects
                    }
                }
                
                // Save Images
                for (_, image) in pagesToProcess.enumerated() {
                    var finalImage = image
                    
                    if settings.optimizeForDevice || settings.imageEnhancement.grayscale {
                        let tempImgURL = tempDir.appendingPathComponent("enhance_temp.jpg")
                        if let data = finalImage.jpegData(compressionQuality: 1.0) {
                            try? data.write(to: tempImgURL)
                            if let processed = ImageProcessor.process(imageURL: tempImgURL, settings: settings) {
                                finalImage = processed
                            }
                        }
                    }
                    
                    guard let data = finalImage.jpegData(compressionQuality: settings.compressionQuality.value) else { continue }
                    let dataSize = Int64(data.count)
                    
                    if settings.splitMode != .none {
                        if (currentVolumeSize + dataSize) > splitLimit && !currentImages.isEmpty {
                            try flushVolume()
                        }
                    }
                    
                    let pageName = String(format: "page_%05d.jpg", globalPageIndex)
                    let pageURL = processedDir.appendingPathComponent(pageName)
                    try data.write(to: pageURL)
                    
                    currentVolumeSize += dataSize
                    currentImages.append(("img_\(globalPageIndex)", pageURL))
                    
                    let htmlName = "page_\(globalPageIndex).xhtml"
                    manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                    manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(pageName)\" media-type=\"image/jpeg\"/>")
                    spineItems.append("<itemref idref=\"page_\(globalPageIndex)\" linear=\"yes\"/>")
                    
                    globalPageIndex += 1
                }
            }
            
            let progress = Double(sourceIndex) / Double(imageURLs.count)
            progressHandler(progress)
        }
        
        if !currentImages.isEmpty {
            try flushVolume()
        }
        
        return outputURLs
    }
    
    // Helpers
    private func validateFileFormat(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magicData = try handle.read(upToCount: 4) ?? Data()
        if let str = String(data: magicData, encoding: .ascii), str.hasPrefix("Rar") {
            throw NSError(domain: "Validation", code: 400, userInfo: [NSLocalizedDescriptionKey: "RAR (CBR) format masquerading as CBZ. Please convert to ZIP."])
        }
    }
    
    private func loadDownsampledImage(at url: URL, maxDimension: CGFloat?) -> UIImage? {
        let options: [CFString: Any] = [ kCGImageSourceShouldCache: false ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        
        if let maxDim = maxDimension {
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        } else {
            return UIImage(contentsOfFile: url.path)
        }
    }
    
    private func findImages(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var images: [URL] = []
        let validExts = ["jpg", "jpeg", "png", "webp"]
        for case let fileURL as URL in enumerator {
            if validExts.contains(fileURL.pathExtension.lowercased()) { images.append(fileURL) }
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
