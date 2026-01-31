import Foundation
import UIKit
import ZIPFoundation
import UniformTypeIdentifiers

// =============================================================================
// MARK: - EPUB GENERATOR CLASS
// =============================================================================

class EPUBGenerator {
    
    private let tempDirectory: URL
    private let settings: EPUBSettings
    private let metadata: PDFMetadata
    private let compressionQuality: Double
    private let targetSize: CGSize? // Added for optimizeForDevice
    private let customScale: Double // Added for custom sliders
    
    private var accumulatedImageManifestItems: String = ""
    private var accumulatedXhtmlManifestItems: String = ""

    private var accumulatedSpineItems: String = ""
    private var accumulatedPageCount: Int = 0
    private var originalSize: Int64 = 0
    private var finalSize: Int64 = 0
    
    init(settings: EPUBSettings, metadata: PDFMetadata, compressionQuality: Double = 0.85, targetSize: CGSize? = nil, customScale: Double = 1.0) {
        self.settings = settings
        self.metadata = metadata
        self.compressionQuality = compressionQuality
        self.targetSize = targetSize
        self.customScale = customScale
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBGeneration_\(UUID().uuidString)", isDirectory: true)
    }
    
    // MARK: - Main Generation Function
    
    func generateEPUB(from images: [UIImage], outputName: String) async throws -> (URL, Int) {
        try createEPUBStructure()
        try await generateContent(from: images)
        try generateMetadataFiles()
        let epubURL = try packageEPUB(outputName: outputName)
        cleanup()
        return (epubURL, accumulatedPageCount)
    }

    func generateEPUB(from imageURLs: [URL], outputName: String, passthrough: Bool = false) async throws -> (URL, Int) {
        try createEPUBStructure()
        try await generateContent(from: imageURLs, passthrough: passthrough)
        try generateMetadataFiles()
        let epubURL = try packageEPUB(outputName: outputName)
        cleanup()
        return (epubURL, accumulatedPageCount)
    }
    
    // MARK: - EPUB Structure Creation
    
    private func createEPUBStructure() throws {
        // Create EPUB directory structure
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("OEBPS/images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("OEBPS/text"), withIntermediateDirectories: true)
        
        // Create mimetype file (must be first, uncompressed)
        let mimetypeURL = tempDirectory.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypeURL, atomically: true, encoding: .utf8)
        
        // Create META-INF/container.xml
        try generateContainerXML()
    }
    
    private func generateContainerXML() throws {
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        
        let containerURL = tempDirectory.appendingPathComponent("META-INF/container.xml")
        try containerXML.write(to: containerURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Content Generation
    


    private func generateContent(from images: [UIImage]) async throws {
        var imageManifestLines: [String] = []
        var xhtmlManifestLines: [String] = []
        var spineItemLines: [String] = []
        
        let imagesDir = tempDirectory.appendingPathComponent("OEBPS/images")
        
        // Process and save images
        for (index, image) in images.enumerated() {
            let pageNumber = index + 1
            let imageName = String(format: "page%d.jpg", pageNumber)
            let imageURL = imagesDir.appendingPathComponent(imageName)
            
            let imageData = image.jpegData(compressionQuality: self.compressionQuality) ?? Data()
            try imageData.write(to: imageURL)
            
            // Add to image manifest items
            let properties = (pageNumber == 1) ? " properties=\"cover-image\"" : ""
            imageManifestLines.append("""
                <item id="image\(pageNumber)" href="images/\(imageName)" media-type="image/jpeg"\(properties)/>
            """)
            
            // Create XHTML page for each image
            let xhtmlFileName = String(format: "page%d.xhtml", pageNumber)
            try createPageXHTML(pageNumber: pageNumber, imageName: imageName, xhtmlFileName: xhtmlFileName)
            
            // Add to XHTML manifest items
            xhtmlManifestLines.append("""
                <item id="page\(pageNumber)" href="text/\(xhtmlFileName)" media-type="application/xhtml+xml"/>
            """)
            
            // Add to spine items
            spineItemLines.append("""
                <itemref idref="page\(pageNumber)"/>
            """)
        }
        
        // Generate page content
        self.accumulatedImageManifestItems = imageManifestLines.joined(separator: "\n")
        self.accumulatedXhtmlManifestItems = xhtmlManifestLines.joined(separator: "\n")
        self.accumulatedSpineItems = spineItemLines.joined(separator: "\n")
        self.accumulatedPageCount = images.count
        
        // Generate table of contents
        if settings.includeTableOfContents {
            try generateTableOfContents(pageCount: images.count)
        }
    }

    private func generateContent(from imageURLs: [URL], passthrough: Bool = false) async throws {
        var imageManifestLines: [String] = []
        var xhtmlManifestLines: [String] = []
        var spineItemLines: [String] = []
        
        let imagesDir = tempDirectory.appendingPathComponent("OEBPS/images")
        
        // Process and save images
        for (index, sourceURL) in imageURLs.enumerated() {
            try autoreleasepool {
                let pageNumber = index + 1
                // Copy image file
                let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
                let imageName = String(format: "page%d.\(ext)", pageNumber)
                let destURL = imagesDir.appendingPathComponent(imageName)
                
                if passthrough {
                     try FileManager.default.copyItem(at: sourceURL, to: destURL)
                     if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path), let size = attrs[.size] as? Int64 {
                         originalSize += size
                         finalSize += size
                     }
                } else {
                    var processed = false
                    
                    // Load image for processing if resizing/compression is needed
                    // "Smart" copying: If no resize needed AND input is JPEG AND quality is High, just copy.
                    // Otherwise, decode -> resize -> compress -> save.
                    
                    let ext = sourceURL.pathExtension.lowercased()
                    let isJPEG = ext == "jpg" || ext == "jpeg"
                    let needsResize = targetSize != nil || customScale < 0.99
                    
                    // Track input size
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path), let size = attrs[.size] as? Int64 {
                        originalSize += size
                    }
                    
                    if !needsResize && isJPEG && compressionQuality >= 1.0 {
                        // Fast path
                        try FileManager.default.copyItem(at: sourceURL, to: destURL)
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path), let size = attrs[.size] as? Int64 {
                            finalSize += size
                        }
                        processed = true
                    }
                    
                    if !processed {
                        // FIX: Use CGImageSource/Destination to avoid UIImage tiling artifacts (horizontal strips)
                        if let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                           let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                            
                            let data = NSMutableData()
                            if let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) {
                                let options: [String: Any] = [
                                    kCGImageDestinationLossyCompressionQuality as String: self.compressionQuality
                                ]
                                
                                CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
                                CGImageDestinationFinalize(destination)
                                
                                try (data as Data).write(to: destURL)
                                finalSize += Int64((data as Data).count)
                                processed = true
                            } else {
                                // Destination creation failed
                                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                                processed = true
                            }
                        } else {
                            // Source creation failed
                            try FileManager.default.copyItem(at: sourceURL, to: destURL)
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                               let size = attrs[.size] as? Int64 {
                                finalSize += size
                            }
                            processed = true
                        }
                    }
                    
                    if !processed {
                       // Fallback
                       try FileManager.default.copyItem(at: sourceURL, to: destURL)
                    }
                }
                
                // Determine media type
                let mediaType: String
                switch ext.lowercased() {
                case "png": mediaType = "image/png"
                case "gif": mediaType = "image/gif"
                case "webp": mediaType = "image/webp"
                default: mediaType = "image/jpeg"
                }
                
                // Add to image manifest items
                let properties = (pageNumber == 1) ? " properties=\"cover-image\"" : ""
                imageManifestLines.append("""
                    <item id="image\(pageNumber)" href="images/\(imageName)" media-type="\(mediaType)"\(properties)/>
                """)
                
                // Create XHTML page for each image
                let xhtmlFileName = String(format: "page%d.xhtml", pageNumber)
                try createPageXHTML(pageNumber: pageNumber, imageName: imageName, xhtmlFileName: xhtmlFileName)
                
                // Add to XHTML manifest items
                xhtmlManifestLines.append("""
                    <item id="page\(pageNumber)" href="text/\(xhtmlFileName)" media-type="application/xhtml+xml"/>
                """)
                
                // Add to spine items
                spineItemLines.append("""
                    <itemref idref="page\(pageNumber)"/>
                """)
            }
        }
        
        // Generate page content
        self.accumulatedImageManifestItems = imageManifestLines.joined(separator: "\n")
        self.accumulatedXhtmlManifestItems = xhtmlManifestLines.joined(separator: "\n")
        self.accumulatedSpineItems = spineItemLines.joined(separator: "\n")
        self.accumulatedPageCount = imageURLs.count
        
        // Generate table of contents
        if settings.includeTableOfContents {
            try generateTableOfContents(pageCount: imageURLs.count)
        }
    }
    
    private func createPageXHTML(pageNumber: Int, imageName: String, xhtmlFileName: String) throws {
        let xhtmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Page \(pageNumber)</title>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
            <style type="text/css">
                body { margin: 0; padding: 0; text-align: center; background-color: white; }
                .page { width: 100vw; height: 100vh; display: flex; align-items: center; justify-content: center; }
                img { max-width: 100%; max-height: 100%; object-fit: contain; }
            </style>
        </head>
        <body>
            <div class="page">
                <img src="../images/\(imageName)" alt="Page \(pageNumber)"/>
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
