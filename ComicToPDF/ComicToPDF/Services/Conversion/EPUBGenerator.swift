import Foundation
import UIKit
import ZIPFoundation
import UniformTypeIdentifiers

// =============================================================================
// MARK: - EPUB GENERATOR CLASS
// =============================================================================

class EPUBGenerator {
    private let settings: EPUBSettings
    private let metadata: PDFMetadata
    private let compressionQuality: Double
    private let targetSize: CGSize?
    private let customScale: Double
    private let tempDirectory: URL
    private let panelData: [Int: [PanelExtractor.Panel]]? // ✅ NEW: Store panel data
    
    init(settings: EPUBSettings, metadata: PDFMetadata, compressionQuality: Double = 0.85, targetSize: CGSize? = nil, customScale: Double = 1.0, panelData: [Int: [PanelExtractor.Panel]]? = nil) {
        self.settings = settings
        self.metadata = metadata
        self.compressionQuality = compressionQuality
        self.targetSize = targetSize
        self.customScale = customScale
        self.panelData = panelData // ✅ NEW
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBGeneration_\(UUID().uuidString)", isDirectory: true)
    }

    // Accumulators for Metadata
    private var accumulatedImageManifestItems = ""
    private var accumulatedXhtmlManifestItems = ""
    private var accumulatedSpineItems = ""
    
    // Stats
    private var originalSize: Int64 = 0
    private var finalSize: Int64 = 0

    // MARK: - Public API
    
    func generateEPUB(images: [UIImage], outputName: String, progress: @escaping (Double) -> Void) async throws -> URL {
        // 1. Setup Directory
        try? FileManager.default.removeItem(at: tempDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        let oebpsDir = tempDirectory.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(at: oebpsDir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebpsDir.appendingPathComponent("text"), withIntermediateDirectories: true)
        let metaInfDir = tempDirectory.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 2. Write Container XML
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 3. Process Images
        let totalImages = images.count
        
        for (index, image) in images.enumerated() {
            let pageNumber = index + 1
            
            // Resize logic
            let processedImage = resizeImageIfNeeded(image)
            
            // Compression
            let imageName = "image\(pageNumber).jpg"
            let imageURL = oebpsDir.appendingPathComponent("images/\(imageName)")
            
            if let data = processedImage.jpegData(compressionQuality: compressionQuality) {
                try data.write(to: imageURL)
                finalSize += Int64(data.count)
                
                // Track Original Size (Approx)
                if let rawData = image.jpegData(compressionQuality: 1.0) {
                     originalSize += Int64(rawData.count)
                }
            }
            
            // Manifest Entry
            accumulatedImageManifestItems += "        <item id=\"image\(pageNumber)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            // XHTML Page
            let xhtmlName = "page\(pageNumber).xhtml"
            try createPageXHTML(pageNumber: pageNumber, imageName: imageName, xhtmlFileName: xhtmlName)
            
            accumulatedXhtmlManifestItems += "        <item id=\"page\(pageNumber)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            accumulatedSpineItems += "        <itemref idref=\"page\(pageNumber)\"/>\n"
            
            progress(Double(index + 1) / Double(totalImages) * 0.9)
        }
        
        // 4. Generate Metadata (OPF/NCX)
        try generateMetadataFiles()
        try generateTableOfContents(pageCount: totalImages)
        
        // 5. Package
        let finalURL = try packageEPUB(outputName: outputName)
        
        cleanup()
        progress(1.0)
        return finalURL
    }
    
    // ✅ NEW: URL-Based overload (for PageDeleteView / Memory Efficiency)
    func generateEPUB(from imageURLs: [URL], outputName: String) async throws -> (URL, Int) {
        // Setup similar to main method but reads from disk
        // Simplified flow: Load images one by one to avoid OOM
        
        try? FileManager.default.removeItem(at: tempDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        let oebpsDir = tempDirectory.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(at: oebpsDir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebpsDir.appendingPathComponent("text"), withIntermediateDirectories: true)
        let metaInfDir = tempDirectory.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // Write Container
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        let totalImages = imageURLs.count
        
        // Streaming Process
        for (index, url) in imageURLs.enumerated() {
            let pageNumber = index + 1
            let imageName = "image\(pageNumber).jpg"
            let imageDestURL = oebpsDir.appendingPathComponent("images/\(imageName)")
            
            // Just copy the file if possible to save re-encoding time?
            // PageDeleteView implies we are editing, so we might want to preserve exact data.
            // But we typically enforce constraints.
            // Let's load and processed like normal to ensure consistency
            
            if let image = UIImage(contentsOfFile: url.path) {
                let processed = resizeImageIfNeeded(image)
                if let data = processed.jpegData(compressionQuality: compressionQuality) {
                     try data.write(to: imageDestURL)
                }
            }
            
            accumulatedImageManifestItems += "        <item id=\"image\(pageNumber)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            let xhtmlName = "page\(pageNumber).xhtml"
            try createPageXHTML(pageNumber: pageNumber, imageName: imageName, xhtmlFileName: xhtmlName)
            
            accumulatedXhtmlManifestItems += "        <item id=\"page\(pageNumber)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            accumulatedSpineItems += "        <itemref idref=\"page\(pageNumber)\"/>\n"
        }
        
        try generateMetadataFiles()
        try generateTableOfContents(pageCount: totalImages)
        
        let finalURL = try packageEPUB(outputName: outputName)
        cleanup()
        
        return (finalURL, totalImages)
    }
    
    // ... (Generate Content methods remain mostly same, just pass through)

    private func createPageXHTML(pageNumber: Int, imageName: String, xhtmlFileName: String) throws {
        // Generate Panels HTML if available
        var panelsHTML = ""
        var extraCSS = ""
        
        if let panels = panelData?[pageNumber], !panels.isEmpty {
            // Amazon Region Magnification Style
            // We need to define "targets" (the magnified view) and "sources" (the tap area)
            // For simple Guided View, the target is usually a high-res crop, OR just a zoomed view of the main image.
            // Modern Kindle 'Region Magnification' uses a DIV overlay that acts as the magnifier.
            
            extraCSS = """
                .app-amzn-magnify {
                     position: absolute;
                     z-index: 2;
                }
            """
            
            // Loop through panels and create overlay divs
            // We'll use percentage-based positioning for universal scaling
            for (index, panel) in panels.enumerated() {
                let pIndex = index + 1
                let rect = panel.boundingBox
                
                // Convert normalized rect (0-1) to percentages
                let top = String(format: "%.2f", (1.0 - rect.maxY) * 100) // CoreGraphics origin is bottom-left, CSS is top-left
                let left = String(format: "%.2f", rect.minX * 100)
                let width = String(format: "%.2f", rect.width * 100)
                let height = String(format: "%.2f", rect.height * 100)
                
                // JSON Data for Kindle
                // {"ord": 1, "parent": "img-container", "ul": [0, 0], "ur": [100, 0], "lr": [100, 100], "ll": [0, 100]}
                // Actually, simplest 'Mag' format is just specifying the target ID.
                // But typically for 'comic' mode, we use:
                // class="app-amzn-magnify" data-app-amzn-magnify='{"targetId":"...","sourceId":"...","ordinal":...}'
                
                // Let's use the standard "overlay" approach
                // We overlay a div that Matches the panel rect.
                
                panelsHTML += """
                <div id="panel-\(pIndex)" class="app-amzn-magnify" 
                     style="top: \(top)%; left: \(left)%; width: \(width)%; height: \(height)%;"
                     data-app-amzn-magnify='{"ordinal":\(pIndex), "type":"panel-target"}'>
                </div>
                """
            }
        }

        let xhtmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Page \(pageNumber)</title>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
            <style type="text/css">
                body { margin: 0; padding: 0; text-align: center; background-color: white; }
                .page { position: relative; width: 100vw; height: 100vh; display: flex; align-items: center; justify-content: center; overflow: hidden; }
                img { max-width: 100%; max-height: 100%; object-fit: contain; z-index: 1; position: absolute; }
                /* Region Magnification Overlays */
                \(extraCSS)
            </style>
        </head>
        <body>
            <div class="page" id="img-container">
                <img src="../images/\(imageName)" alt="Page \(pageNumber)"/>
                \(panelsHTML)
            </div>
        </body>
        </html>
        """
        
        let pageURL = tempDirectory.appendingPathComponent("OEBPS/text/page\(pageNumber).xhtml")
        try xhtmlContent.write(to: pageURL, atomically: true, encoding: .utf8)
    }
    
    private func generateTableOfContents(pageCount: Int) throws {
        let tocContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Table of Contents</title>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
        </head>
        <body>
            <h1>Table of Contents</h1>
            <nav>
                <ol>
        \(generateTOCEntries(pageCount: pageCount))
                </ol>
            </nav>
        </body>
        </html>
        """
        
        let tocURL = tempDirectory.appendingPathComponent("OEBPS/text/toc.xhtml")
        try tocContent.write(to: tocURL, atomically: true, encoding: .utf8)
    }
    
    private func generateTOCEntries(pageCount: Int) -> String {
        return (1...pageCount).map { pageNumber in
            "                    <li><a href=\"page\(pageNumber).xhtml\">Page \(pageNumber)</a></li>"
        }.joined(separator: "\n")
    }
    
    // MARK: - Metadata Files Generation
    
    private func generateMetadataFiles() throws {
        try generateContentOPF()
        try generateTocNCX()
    }
    
    private func generateContentOPF() throws {
        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:identifier id="BookID">\(UUID().uuidString)</dc:identifier>
                <dc:title>\(metadata.title.isEmpty ? "Comic Book" : metadata.title)</dc:title>
                <dc:creator>\((metadata.author?.isEmpty ?? true) ? "Unknown" : metadata.author!)</dc:creator>
                <dc:language>en</dc:language>
                <dc:description>\((metadata.summary?.isEmpty ?? true) ? "Comic book converted from CBZ/CBR" : metadata.summary!)</dc:description>
                <dc:publisher>\((metadata.publisher?.isEmpty ?? true) ? "Inksync Pro" : metadata.publisher!)</dc:publisher>
                <dc:date>\(ISO8601DateFormatter().string(from: Date()))</dc:date>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta name="region-mag" content="true"/>
                <meta name="cover" content="image1"/>
            </metadata>
            <manifest>
                <item id="toc" href="text/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(accumulatedImageManifestItems)
        \(accumulatedXhtmlManifestItems)
            </manifest>
            <spine page-progression-direction="\(settings.readingDirection.rawValue)">
        \(accumulatedSpineItems)
            </spine>
        </package>
        """
        
        let contentURL = tempDirectory.appendingPathComponent("OEBPS/content.opf")
        try contentOPF.write(to: contentURL, atomically: true, encoding: String.Encoding.utf8)
    }
    
    private func generateTocNCX() throws {
        // Generate legacy NCX file for older readers
        let pageCount = try FileManager.default.contentsOfDirectory(at: tempDirectory.appendingPathComponent("OEBPS/images"), includingPropertiesForKeys: nil).count
        
        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
            <head>
                <meta name="dtb:uid" content="\(UUID().uuidString)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pageCount)"/>
                <meta name="dtb:maxPageNumber" content="\(pageCount)"/>
            </head>
            <docTitle>
                <text>\(metadata.title.isEmpty ? "Comic Book" : metadata.title)</text>
            </docTitle>
            <navMap>
        \(generateNCXNavPoints(pageCount: pageCount))
            </navMap>
        </ncx>
        """
        
        let ncxURL = tempDirectory.appendingPathComponent("OEBPS/toc.ncx")
        try tocNCX.write(to: ncxURL, atomically: true, encoding: .utf8)
    }
    
    private func generateNCXNavPoints(pageCount: Int) -> String {
        return (1...pageCount).map { pageNumber in
            """
                    <navPoint id="navpoint-\(pageNumber)" playOrder="\(pageNumber)">
                        <navLabel>
                            <text>Page \(pageNumber)</text>
                        </navLabel>
                        <content src="text/page\(pageNumber).xhtml"/>
                    </navPoint>
            """
        }.joined(separator: "\n")
    }
    
    // MARK: - EPUB Packaging
    
    private func packageEPUB(outputName: String) throws -> URL {
        // Output to a temporary file initially
        let outputURL = tempDirectory.deletingLastPathComponent().appendingPathComponent("\(outputName).epub")
        
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        let archive = try Archive(url: outputURL, accessMode: .create)
        
        // 1. Mimetype (MUST be first and uncompressed)
        let mimetypeURL = tempDirectory.appendingPathComponent("mimetype")
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(20), compressionMethod: .none) { position, size in
            return try Data(contentsOf: mimetypeURL).subdata(in: 0..<Int(size))
        }
        
        // 2. Add remaining files (META-INF, OEBPS)
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: tempDirectory, includingPropertiesForKeys: resourceKeys)!
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = resourceValues.isDirectory ?? false
            
            // Get relative path
            let path = fileURL.path.replacingOccurrences(of: tempDirectory.path + "/", with: "")
            
            // Skip mimetype as we added it already (and temp directory root)
            if path == "mimetype" || path.isEmpty { continue }
            
            if !isDirectory {
                let fileSize = UInt32(resourceValues.fileSize ?? 0)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(fileSize), compressionMethod: .deflate) { position, size in
                    return try Data(contentsOf: fileURL).subdata(in: 0..<Int(size))
                }
            } else {
                 // Directories are implicit or added as 0-size entries in some zip implementations, 
                 // but ZIPFoundation typically handles file paths. We can skip explicit directory entries
                 // unless necessary, but adding them doesn't hurt.
                 try archive.addEntry(with: path + "/", type: .directory, uncompressedSize: Int64(0), compressionMethod: .none) { _, _ in Data() }
            }
        }
        
        return outputURL
    }
    
    // MARK: - Helper Methods
    
    private func resizeImageIfNeeded(_ image: UIImage) -> UIImage {
        // Use consistent pixel dimensions (CGImage)
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let originalSize = CGSize(width: width, height: height)
        
        // Safety check
        guard originalSize.width > 0, originalSize.height > 0 else { return image }
        
        // check if we have a target
        guard let target = targetSize, target.width > 0, target.height > 0 else {
            // No target, just bespoke scaling if any
             if customScale < 0.99 && customScale > 0 {
                let newSize = CGSize(width: originalSize.width * customScale, height: originalSize.height * customScale)
                return performResize(image, to: newSize)
             }
             return image
        }
        
        // ✅ SMART RESIZING (KCC Logic)
        // 1. Calculate Target Aspect Ratio
        let targetRatio = target.width / target.height
        let imageRatio = originalSize.width / originalSize.height
        
        var newSize = originalSize
        
        // 2. Scale to Fit Target (Upscale OR Downscale)
        // We want to fill the target as much as possible while maintaining aspect ratio.
        if imageRatio > targetRatio {
            // Image is wider than target (Letterbox Top/Bottom)
            // Width dictates scale
            let scale = target.width / originalSize.width
            newSize = CGSize(width: target.width, height: originalSize.height * scale)
        } else {
            // Image is taller than target (Pillarbox Left/Right)
            // Height dictates scale
            let scale = target.height / originalSize.height
            newSize = CGSize(width: originalSize.width * scale, height: target.height)
        }
        
        // 3. Render into Target Canvas (Matte)
        // This ensures the output is ALWAYS exact device resolution
        return performResize(image, to: newSize, canvasSize: target)
    }
    
    // Helper to perform the actual drawing
    private func performResize(_ image: UIImage, to size: CGSize, canvasSize: CGSize? = nil) -> UIImage {
        let finalCanvas = canvasSize ?? size
        
        // Check for sanity
        if finalCanvas.width > 5000 || finalCanvas.height > 5000 { return image }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true // No alpha channel = smaller file
        
        let renderer = UIGraphicsImageRenderer(size: finalCanvas, format: format)
        return renderer.image { context in
            // Fill with White (Standard for E-Ink / Paper)
            // Or Black if requested (future feature)
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: finalCanvas))
            
            // Center the image
            let originX = (finalCanvas.width - size.width) / 2
            let originY = (finalCanvas.height - size.height) / 2
            
            image.draw(in: CGRect(x: originX, y: originY, width: size.width, height: size.height))
        }
    }
    
    func printCompressionStats() {
        if originalSize > 0 {
             let percent = 100.0 * (1.0 - (Double(finalSize) / Double(originalSize)))
             print("📉 Compression Stats: Original: \(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file)) -> EPUB Content: \(ByteCountFormatter.string(fromByteCount: finalSize, countStyle: .file)) (\(String(format: "%.1f", percent))% reduction)")
        }
    }

    // MARK: - Cleanup
    
    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}
