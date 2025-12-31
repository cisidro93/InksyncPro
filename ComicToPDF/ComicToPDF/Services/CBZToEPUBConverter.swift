import UIKit
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convertCBZToEPUB(_ cbzURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Extract CBZ
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                print("📦 Extracting CBZ...")
                try FileManager.default.unzipItem(at: cbzURL, to: tempDir)
                
                // 2. Get comic pages (images) in order
                let pageImages = try self.extractComicPages(from: tempDir)
                print("📄 Found \(pageImages.count) pages")
                
                // 3. Create EPUB structure with FULL pages (no slicing!)
                let epubURL = try self.createEPUB(
                    from: pageImages,
                    title: cbzURL.deletingPathExtension().lastPathComponent,
                    outputDir: tempDir
                )
                
                print("✅ EPUB created: \(epubURL.lastPathComponent)")
                
                DispatchQueue.main.async {
                    completion(.success(epubURL))
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // Extract comic pages WITHOUT slicing
    private func extractComicPages(from directory: URL) throws -> [UIImage] {
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
        images.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        
        return images.map { $0.image }
    }
    
    // Create proper EPUB with full pages (NOT strips!)
    private func createEPUB(from pages: [UIImage], title: String, outputDir: URL) throws -> URL {
        
        // Create EPUB directory structure
        let epubDir = outputDir.appendingPathComponent("epub_temp")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        
        // 1. Create mimetype file
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        
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
        var spineItems = ""
        
        for (index, page) in pages.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let imageName = "page\(pageNum).jpg"
            let imageURL = imagesDir.appendingPathComponent(imageName)
            
            // Save COMPLETE image (not sliced!)
            if let jpegData = page.jpegData(compressionQuality: 0.9) {
                try jpegData.write(to: imageURL)
                print("💾 Saved full page: \(imageName) - \(Int(page.size.width))x\(Int(page.size.height))")
            }
            
            // Add to manifest
            imageManifest += """
                <item id="img\(pageNum)" href="images/\(imageName)" media-type="image/jpeg"/>
                <item id="page\(pageNum)" href="page\(pageNum).xhtml" media-type="application/xhtml+xml"/>
            
            """
            
            spineItems += """
                <itemref idref="page\(pageNum)"/>
            
            """
            
            // Create XHTML page that displays the FULL image
            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <style>
                    body { margin: 0; padding: 0; }
                    img { width: 100%; height: 100%; object-fit: contain; }
                </style>
            </head>
            <body>
                <img src="images/\(imageName)" alt="Page \(index + 1)"/>
            </body>
            </html>
            """
            try xhtml.write(to: oebpsDir.appendingPathComponent("page\(pageNum).xhtml"), atomically: true, encoding: .utf8)
        }
        
        // 4. Create content.opf
        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:language>en</dc:language>
                <dc:identifier id="uid">comic-\(UUID().uuidString)</dc:identifier>
            </metadata>
            <manifest>
        \(imageManifest)
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            </manifest>
            <spine toc="ncx">
        \(spineItems)
            </spine>
        </package>
        """
        try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 5. Create toc.ncx
        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="comic-\(UUID().uuidString)"/>
            </head>
            <docTitle><text>\(title)</text></docTitle>
            <navMap>
                <navPoint id="navpoint-1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="page0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try tocNCX.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 6. Zip into .epub
        let epubURL = outputDir.appendingPathComponent("\(title).epub")
        try FileManager.default.zipItem(at: epubDir, to: epubURL)
        
        print("📚 EPUB created with \(pages.count) FULL pages (no strips!)")
        
        return epubURL
    }
}
