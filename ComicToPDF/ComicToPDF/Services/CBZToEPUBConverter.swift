import UIKit
import ZIPFoundation
import ImageIO
import MobileCoreServices
import Foundation

class CBZToEPUBConverter {
    
    /// Converts a CBZ file to EPUB with Smart Stitching.
    /// - Parameters:
    ///   - cbzURL: The source CBZ URL.
    ///   - compressionQuality: 1.0 = Direct Copy (Original), < 1.0 = Re-encode (Compressed).
    func convertCBZToEPUB(_ cbzURL: URL, compressionQuality: Double) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // 1. Setup Temp Directory
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    
                    print("📦 Extracting CBZ...")
                    try FileManager.default.unzipItem(at: cbzURL, to: tempDir)
                    
                    // 2. Scan and Group Pages (Smart Stitching Logic)
                    // Instead of just finding files, we now group them into ComicPageModel objects
                    let rawImageURLs = try CBZToEPUBConverter.scanRawImageURLs(in: tempDir)
                    let pageModels = ComicStitcher.analyzeAndGroup(imageURLs: rawImageURLs)
                    
                    print("📄 Raw files: \(rawImageURLs.count) -> 📖 Stitched Pages: \(pageModels.count)")
                    
                    if pageModels.isEmpty {
                        throw NSError(domain: "CBZConverter", code: 404, userInfo: [NSLocalizedDescriptionKey: "No supported images found in CBZ."])
                    }
                    
                    // 3. Generate EPUB Structure
                    let epubURL = try CBZToEPUBConverter.buildEPUB(
                        from: pageModels,
                        title: cbzURL.deletingPathExtension().lastPathComponent,
                        outputDir: tempDir,
                        compressionQuality: compressionQuality
                    )
                    
                    // 4. Move to Safe Location (Persistent Temp)
                    let safeFileName = epubURL.lastPathComponent
                    let safeURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeFileName)
                    try? FileManager.default.removeItem(at: safeURL)
                    try FileManager.default.moveItem(at: epubURL, to: safeURL)
                    
                    print("✅ EPUB created successfully: \(safeURL.path)")
                    continuation.resume(returning: safeURL)
                    
                } catch {
                    print("❌ CBZ Conversion Failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private static func scanRawImageURLs(in directory: URL) throws -> [URL] {
        var urls: [URL] = []
        let supportedExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    // Skip MacOS metadata
                    if fileURL.lastPathComponent.hasPrefix("._") || fileURL.path.contains("__MACOSX") {
                        continue
                    }
                    urls.append(fileURL)
                }
            }
        }
        
        // Sort alphanumerically to ensure correct page order
        urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return urls
    }
    
    /// Builds the EPUB file structure using PageModels
    private static func buildEPUB(from pages: [ComicPageModel], title: String, outputDir: URL, compressionQuality: Double) throws -> URL {
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 1. Mimetype
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        
        // 2. Container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 3. Process Images & content.opf manifests
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, pageModel) in pages.enumerated() {
            let pageNumStr = String(format: "%04d", index + 1)
            let imageName = "page\(pageNumStr).jpg"
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // --- SMART STITCHING PIPELINE ---
            var finalImage: UIImage?
            
            if pageModel.isComposite {
                // Stitch logic: Load all images in the group
                let sourceImages = pageModel.images.compactMap { UIImage(contentsOfFile: $0.path) }
                finalImage = ComicStitcher.stitchImagesVertically(sourceImages)
                print("🧩 Stitched \(sourceImages.count) strips for page \(index + 1)")
            } else {
                // Single page logic
                if let url = pageModel.images.first {
                    finalImage = UIImage(contentsOfFile: url.path)
                }
            }
            
            guard let imageToProcess = finalImage, let cgImage = imageToProcess.cgImage else {
                print("⚠️ Could not process page \(index + 1)")
                continue
            }
            
            // --- RESIZING & COMPRESSION ---
            let sourceWidth = CGFloat(cgImage.width)
            let sourceHeight = CGFloat(cgImage.height)
            let maxDimension: CGFloat = 2400
            
            var targetWidth = sourceWidth
            var targetHeight = sourceHeight
            
            // Downscale if too massive (e.g., long stitched strip)
            if sourceWidth > maxDimension || sourceHeight > 3200 { // Allow more height for vertical strips
                let scale = min(
                    maxDimension / sourceWidth,
                    3200 / sourceHeight, // Cap height to prevent crash on older devices
                    1.0
                )
                targetWidth = (sourceWidth * scale).rounded()
                targetHeight = (sourceHeight * scale).rounded()
            }
            
            let targetSize = CGSize(width: targetWidth, height: targetHeight)
            
            // Render final JPEG
            let rendererFormat = UIGraphicsImageRendererFormat()
            rendererFormat.opaque = true
            rendererFormat.scale = 1.0 // Force 1x scale to keep pixels exact
            
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat)
            let processedData = renderer.image { context in
                // High quality interpolation
                context.cgContext.interpolationQuality = .high
                imageToProcess.draw(in: CGRect(origin: .zero, size: targetSize))
            }.jpegData(compressionQuality: compressionQuality)
            
            if let data = processedData {
                try data.write(to: imageDestURL)
            } else {
                continue
            }
            
            // --- MANIFEST GENERATION ---
            imageManifest += "<item id=\"img_\(pageNumStr)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            let xhtmlContent = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <link href="../styles.css" type="text/css" rel="stylesheet"/>
                <meta name="viewport" content="width=\(Int(targetWidth)), height=\(Int(targetHeight))" />
            </head>
            <body style="margin:0;padding:0;background-color:black;">
                <div style="text-align:center;height:100vh;display:flex;justify-content:center;align-items:center;">
                    <img src="../images/\(imageName)" alt="Page \(index + 1)" style="max-width:100%;max-height:100%;"/>
                </div>
            </body>
            </html>
            """
            
            let xhtmlName = "page\(pageNumStr).xhtml"
            try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
            
            xhtmlManifest += "<item id=\"page_\(pageNumStr)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "<itemref idref=\"page_\(pageNumStr)\"/>\n"
        }
        
        // 4. content.opf
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(title)</dc:title>
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:language>en</dc:language>
                <meta name="cover" content="img_0001"/>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                \(imageManifest)
                \(xhtmlManifest)
            </manifest>
            <spine toc="ncx">
                \(spineItems)
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 5. toc.ncx
        let finalPageCount = pages.count
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="urn:uuid:\(UUID().uuidString)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(finalPageCount)"/>
                <meta name="dtb:maxPageNumber" content="\(finalPageCount)"/>
            </head>
            <docTitle><text>\(title)</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 6. Zip (Manual Archive)
        let finalEPUB = outputDir.appendingPathComponent("\(title).epub")
        let archive = try Archive(url: finalEPUB, accessMode: .create)
        
        // Add mimetype (Uncompressed)
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(20), compressionMethod: .none) { position, size in
            return try Data(contentsOf: epubDir.appendingPathComponent("mimetype")).subdata(in: 0..<Int(size))
        }
        
        // Add Content (Deflate)
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: epubDir, includingPropertiesForKeys: resourceKeys)!
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = resourceValues.isDirectory ?? false
            let path = fileURL.path.replacingOccurrences(of: epubDir.path + "/", with: "")
            
            if path == "mimetype" || path.isEmpty { continue }
            
            if !isDirectory {
                let fileSize = UInt32(resourceValues.fileSize ?? 0)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(fileSize), compressionMethod: .deflate) { position, size in
                    return try Data(contentsOf: fileURL).subdata(in: 0..<Int(size))
                }
            }
        }
        
        return finalEPUB
    }
}
