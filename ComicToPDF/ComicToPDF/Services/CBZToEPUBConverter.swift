import UIKit
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convertCBZToEPUB(_ cbzURL: URL, compressionQuality: Double) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // 1. Extract CBZ
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    
                    print("📦 Extracting CBZ...")
                    try FileManager.default.unzipItem(at: cbzURL, to: tempDir)
                    
                    // 2. Get comic pages (images) in order
                    let pageImages = try CBZToEPUBConverter.extractComicPages(from: tempDir)
                    print("📄 Found \(pageImages.count) pages")
                    
                    // 3. Create EPUB structure with FULL pages (no slicing!)
                    let epubURL = try CBZToEPUBConverter.createEPUB(
                        from: pageImages,
                        title: cbzURL.deletingPathExtension().lastPathComponent,
                        outputDir: tempDir,
                        compressionQuality: compressionQuality
                    )
                    
                    print("✅ EPUB created: \(epubURL.lastPathComponent)")
                    
                    continuation.resume(returning: epubURL)
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // Extract comic pages WITHOUT slicing
    private static func extractComicPages(from directory: URL) throws -> [UIImage] {
        var images: [(url: URL, image: UIImage)] = []
        
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                    if let image = UIImage(contentsOfFile: fileURL.path) {
                        images.append((url: fileURL, image: image))
                    }
                }
            }
        }
        
        // Sort by filename to maintain page order
        images.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        
        return images.map { $0.image }
    }
    
    // Create proper EPUB with full pages (NOT strips!)
    private static func createEPUB(from pages: [UIImage], title: String, outputDir: URL, compressionQuality: Double) throws -> URL {
        
        // Create EPUB directory structure
        let epubDir = outputDir.appendingPathComponent("epub_temp")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        // 1. Create mimetype file
        let mimetypeURL = epubDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypeURL, atomically: true, encoding: .utf8)
        
        // 2. Create container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 3. Save FULL page images (NO SLICING!)
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, page) in pages.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let imageName = "page\(pageNum).jpg"
            let imageURL = imagesDir.appendingPathComponent(imageName)
            let xhtmlName = "page\(pageNum).xhtml"
            
            // Save COMPLETE image (not sliced!)
            if let jpegData = page.jpegData(compressionQuality: compressionQuality) {
                try jpegData.write(to: imageURL)
                
                imageManifest += """
                        <item id="img_\(pageNum)" href="images/\(imageName)" media-type="image/jpeg"/>
                
                """
                
                // Create XHTML wrapper
                let xhtmlContent = """
                <?xml version="1.0" encoding="utf-8"?>
                <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head>
                    <title>Page \(index + 1)</title>
                    <link href="../styles.css" type="text/css" rel="stylesheet"/>
                    <meta name="viewport" content="width=\(Int(page.size.width)), height=\(Int(page.size.height))" />
                </head>
                <body style="margin:0;padding:0">
                    <div style="text-align:center">
                        <img src="../images/\(imageName)" alt="Page \(index + 1)" style="height:100%;max-width:100%"/>
                    </div>
                </body>
                </html>
                """
                
                let xhtmlURL = textDir.appendingPathComponent(xhtmlName)
                try xhtmlContent.write(to: xhtmlURL, atomically: true, encoding: .utf8)
                
                xhtmlManifest += """
                        <item id="page_\(pageNum)" href="text/\(xhtmlName)" media-type="application/xhtml+xml"/>
                
                """
                
                spineItems += """
                        <itemref idref="page_\(pageNum)"/>
                
                """
            }
        }
        
        // 4. Create Opf file
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(title)</dc:title>
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:language>en</dc:language>
                <meta name="cover" content="img_0001"/>
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
        
        // 5. Create NCX
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="urn:uuid:\(UUID().uuidString)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pages.count)"/>
                <meta name="dtb:maxPageNumber" content="\(pages.count)"/>
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
        
        // 6. Manual Zip (using ZIPFoundation)
        let finalEPUB = outputDir.appendingPathComponent("\(title).epub")
        
        let archive = try Archive(url: finalEPUB, accessMode: .create)
        
        // Add mimetype first (uncompressed)
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(20), compressionMethod: .none) { position, size in
            return try Data(contentsOf: mimetypeURL).subdata(in: 0..<Int(size))
        }
        
        // Add content directory
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
