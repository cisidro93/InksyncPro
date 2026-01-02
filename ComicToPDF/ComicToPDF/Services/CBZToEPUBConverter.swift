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
    
    private static func scanComicPages(in directory: URL) throws -> [PageInfo] {
        var pages: [PageInfo] = []
        let supportedExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    // ✅ SKIP MACOS METADATA FILES (same as PDF converter)
                    if fileURL.lastPathComponent.hasPrefix("._") || fileURL.path.contains("__MACOSX") {
                        continue  // Skip metadata files
                    }
                    
                    // ✅ USE UIImage LIKE THE PDF CONVERTER DOES!
                    if let image = UIImage(contentsOfFile: fileURL.path) {
                        let width = Int(image.size.width)
                        let height = Int(image.size.height)
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
            let pageNumStr = String(format: "%04d", index + 1)
            let imageName = "page\(pageNumStr).jpg"  // Always JPG for EPUB
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // ✅ LOAD IMAGE THE SAME WAY PDF CONVERTER DOES
            if let originalImage = UIImage(contentsOfFile: page.url.path) {
                
                // Determine target size (reasonable for e-readers)
                let maxDimension: CGFloat = 2400
                var targetSize = originalImage.size
                
                if originalImage.size.width > maxDimension || originalImage.size.height > maxDimension {
                    let scale = min(
                        maxDimension / originalImage.size.width,
                        maxDimension / originalImage.size.height,
                        1.0
                    )
                    targetSize = CGSize(
                        width: (originalImage.size.width * scale).rounded(),
                        height: (originalImage.size.height * scale).rounded()
                    )
                }
                
                // ✅ PROCESS IMAGE THE SAME WAY PDF CONVERTER DOES
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1.0
                format.opaque = true
                
                let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
                let processedImage = renderer.image { _ in
                    originalImage.draw(in: CGRect(origin: .zero, size: targetSize))
                }
                
                // Save as JPEG
                if let jpegData = processedImage.jpegData(compressionQuality: compressionQuality) {
                    try jpegData.write(to: imageDestURL)
                } else {
                    print("⚠️ Failed to save \(imageName)")
                    continue
                }
            } else {
                print("❌ Could not load \(page.url.lastPathComponent)")
                continue
            }
            
            // Generate manifest entries
            imageManifest += "<item id=\"img_\(pageNumStr)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            // Generate XHTML with correct dimensions
            let finalWidth = Int(page.width) // Fallback to scanned width if needed, or re-measure
            let finalHeight = Int(page.height)
            
            // NOTE: The user's code snippet calculated finalWidth/Height from originalImage, but originalImage scope is closed above.
            // However, page.width and page.height are now sourced from UIImage in scanComicPages, so they are accurate.
            
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
