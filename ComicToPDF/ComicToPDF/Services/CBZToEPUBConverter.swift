import Foundation
import UIKit
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: EPUBSettings, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 1. Unzip
        progressHandler(0.1)
        try fileManager.unzipItem(at: sourceURL, to: tempDir)
        
        // 2. Find Images
        let imageURLs = try findImages(in: tempDir)
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "Conversion", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        
        // 3. Structure
        progressHandler(0.2)
        let epubDir = tempDir.appendingPathComponent("EPUB_Build")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        
        // 4. CSS (Strict Reset)
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body { 
            margin: 0; padding: 0; 
            width: 100vw; height: 100vh; 
            background-color: #000000;
        }
        div.svg-wrapper {
            width: 100%; height: 100%;
            margin: 0; padding: 0;
            text-align: center;
        }
        img { 
            height: 100%; width: auto; 
            max-width: 100%; object-fit: contain; 
        }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
        // 5. Process Images
        var manifestItems: [String] = []
        var spineItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/style.css\" media-type=\"text/css\"/>")
        
        for (index, imgURL) in imageURLs.enumerated() {
            let fileExt = imgURL.pathExtension.lowercased()
            let newName = "page_\(String(format: "%03d", index + 1)).\(fileExt)"
            let destURL = imagesDir.appendingPathComponent(newName)
            try fileManager.moveItem(at: imgURL, to: destURL)
            
            let mimeType = (fileExt == "png") ? "image/png" : "image/jpeg"
            
            // Mark first image as cover-image
            let properties = (index == 0) ? "properties=\"cover-image\"" : ""
            manifestItems.append("<item id=\"img_\(index)\" href=\"images/\(newName)\" media-type=\"\(mimeType)\" \(properties)/>")
            
            // HTML
            let htmlContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
                <link rel="stylesheet" type="text/css" href="css/style.css"/>
            </head>
            <body>
                <div class="svg-wrapper">
                    <img src="images/\(newName)" alt=""/>
                </div>
            </body>
            </html>
            """
            
            let htmlName = "page_\(index).xhtml"
            try htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"page_\(index)\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
            
            // ✅ Fix: All pages are linear="yes"
            spineItems.append("<itemref idref=\"page_\(index)\" linear=\"yes\"/>")
            
            progressHandler(0.2 + (0.7 * Double(index) / Double(imageURLs.count)))
        }
        
        // ✅ Fix: Add Nav to spine LAST and mark linear="no" to hide it from swipe flow
        spineItems.append("<itemref idref=\"nav\" linear=\"no\"/>")
        
        // 6. Metadata (OPF)
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(sourceURL.deletingPathExtension().lastPathComponent)</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
                <meta name="cover" content="img_0"/>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n"))
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            </manifest>
            <spine page-progression-direction="ltr">
                \(spineItems.joined(separator: "\n"))
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="page_0.xhtml"/>
            </guide>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 7. Navigation (Hidden Style)
        // ✅ Fix: Added 'hidden' attribute and empty list to prevent visual rendering if reader forces it
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" hidden="">
        <head><title>Navigation</title></head>
        <body>
            <nav epub:type="toc" id="toc" hidden="">
                <ol hidden="">
                    <li><a href="page_0.xhtml">Cover</a></li>
                </ol>
            </nav>
        </body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 8. Container
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 9. Zip
        progressHandler(0.95)
        let finalName = sourceURL.deletingPathExtension().lastPathComponent + ".epub"
        let destURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(finalName)
        
        if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
        try fileManager.zipItem(at: epubDir, to: destURL)
        
        progressHandler(1.0)
        return destURL
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
