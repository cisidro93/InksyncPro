import UIKit
import ZIPFoundation
import ImageIO
import MobileCoreServices
import Foundation

class CBZToEPUBConverter {
    
    struct PageInfo {
        let url: URL
        let width: Int
        let height: Int
        let originalExtension: String
    }
    
    /// Converts a CBZ file to EPUB.
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
                    
                    // 2. Scan for Pages (Metadata Only - No Loading)
                    let pages = try CBZToEPUBConverter.scanComicPages(in: tempDir)
                    print("📄 Found \(pages.count) pages")
                    
                    if pages.isEmpty {
                        throw NSError(domain: "CBZConverter", code: 404, userInfo: [NSLocalizedDescriptionKey: "No supported images found in CBZ."])
                    }
                    
                    // 3. Generate EPUB Structure
                    let epubURL = try CBZToEPUBConverter.buildEPUB(
                        from: pages,
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
    
    /// Scans directory for images and extracts dimensions using ImageIO (Fast, Low Memory).
    private static func scanComicPages(in directory: URL) throws -> [PageInfo] {
        var pages: [PageInfo] = []
        let supportedExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    // Use ImageIO to get dimensions without decoding
                    if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                        
                        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 1000
                        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 1500
                        
                        pages.append(PageInfo(url: fileURL, width: width, height: height, originalExtension: ext))
                    }
                }
            }
        }
        
        // Sort alphanumerically
        pages.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return pages
    }
    
    /// Builds the EPUB file structure.
    private static func buildEPUB(from pages: [PageInfo], title: String, outputDir: URL, compressionQuality: Double) throws -> URL {
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
        
        for (index, page) in pages.enumerated() {
            let isDirectCopy = compressionQuality >= 1.0
            
            // 1. Check Dimensions & Safety Resize
            var finalImageSource: CGImageSource? = nil
            var shouldResize = false
            
            if let source = CGImageSourceCreateWithURL(page.url as CFURL, nil) {
                finalImageSource = source
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? page.height
                    // Safety Limit: 4000px (WebKit texture limit is often 4096px or 8192px)
                    // Resizing ensures no tiling/stripping artifacts.
                    if height > 4000 {
                        shouldResize = true
                    }
                }
            }
            
            // NORMAL MODE (Direct Copy or Transcode or Resize)
            let pageNumStr = String(format: "%04d", index + 1)
            
            // If Direct Copy & No Resize: Keep original extension
            // If Compressed OR Resized: Force JPG
            let finalExt = (isDirectCopy && !shouldResize) ? page.originalExtension : "jpg"
            let imageName = "page\(pageNumStr).\(finalExt)"
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // Execution
            if shouldResize, let source = finalImageSource {
                // RESIZE MODE (Thumbnailing)
                let options: [String: Any] = [
                    kCGImageSourceCreateThumbnailStart as String: NSNumber(value: true),
                    kCGImageSourceCreateThumbnailFromImageAlways as String: NSNumber(value: true),
                    kCGImageSourceThumbnailMaxPixelSize as String: NSNumber(value: 4000),
                    kCGImageSourceCreateThumbnailWithTransform as String: NSNumber(value: true)
                ]
                
                if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    if let destination = CGImageDestinationCreateWithURL(imageDestURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                         let destOptions: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: NSNumber(value: compressionQuality)]
                         CGImageDestinationAddImage(destination, thumbnail, destOptions as CFDictionary)
                         CGImageDestinationFinalize(destination)
                    }
                } else {
                     // Fallback if thumbnail fails
                     try? FileManager.default.copyItem(at: page.url, to: imageDestURL)
                }
                
            } else if isDirectCopy {
                // DIRECT COPY
                try FileManager.default.copyItem(at: page.url, to: imageDestURL)
            } else {
                // TRANSCODE (Existing Logic)
                var compressionSuccess = false
                
                if let source = finalImageSource {
                    if let destination = CGImageDestinationCreateWithURL(imageDestURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                    if let destination = CGImageDestinationCreateWithURL(imageDestURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                        let options: [String: Any] = [
                            kCGImageDestinationLossyCompressionQuality as String: NSNumber(value: compressionQuality)
                        ]
                        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
                        if CGImageDestinationFinalize(destination) { compressionSuccess = true }
                    }
                }
                
                if !compressionSuccess {
                    print("⚠️ ImageIO Compression failed for \(imageName). Falling back to direct copy.")
                    try? FileManager.default.removeItem(at: imageDestURL)
                    try FileManager.default.copyItem(at: page.url, to: imageDestURL)
                }
            }
            
            // Determine Media Type
            let mediaType: String
            switch finalExt.lowercased() {
            case "png": mediaType = "image/png"
            case "gif": mediaType = "image/gif"
            case "webp": mediaType = "image/webp"
            default: mediaType = "image/jpeg"
            }
            
            // Add to Manifests
            imageManifest += "<item id=\"img_\(pageNumStr)\" href=\"images/\(imageName)\" media-type=\"\(mediaType)\"/>\n"
            
            // Update Page dimensions for Viewport (Important if resized)
            var finalWidth = page.width
            var finalHeight = page.height
            if shouldResize {
                // Estimate new dimensions (proportional)
                 if page.height > 0 {
                     let ratio = Double(page.width) / Double(page.height)
                     finalHeight = 4000
                     finalWidth = Int(Double(finalHeight) * ratio)
                 }
            }
            
            // Generate XHTML
            let xhtmlContent = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <link href="../styles.css" type="text/css" rel="stylesheet"/>
                <meta name="viewport" content="width=\(finalWidth), height=\(finalHeight)" />
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
        // Calculate Actual Page Count
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
