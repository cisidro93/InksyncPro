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
        
        // 3. Setup EPUB Structure
        progressHandler(0.2)
        let epubDir = tempDir.appendingPathComponent("EPUB_Build")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        
        // 4. Create CSS (The Layout Fix)
        // We use a strict CSS reset to ensure no margins push content off screen.
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body { 
            margin: 0; 
            padding: 0; 
            height: 100vh; 
            width: 100vw; 
            background-color: #000000;
            display: flex; 
            justify-content: center; 
            align-items: center;
            overflow: hidden; /* Prevents blank overflow pages */
        }
        img { 
            max-height: 100%; 
            max-width: 100%; 
            object-fit: contain; 
        }
        /* SVG Wrapper method for perfect Kindle scaling */
        div.svg-wrapper {
            width: 100vw;
            height: 100vh;
            margin: 0;
            text-align: center;
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
            
            // Get dimensions for SVG wrapper (Best practice for Comics)
            var width = 1000
            var height = 1500
            if let imageSource = CGImageSourceCreateWithURL(destURL as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                width = properties[kCGImagePropertyPixelWidth] as? Int ?? 1000
                height = properties[kCGImagePropertyPixelHeight] as? Int ?? 1500
            }
            
            // Mime Type
            let mimeType = (fileExt == "png") ? "image/png" : "image/jpeg"
            
            manifestItems.append("<item id=\"img_\(index)\" href=\"images/\(newName)\" media-type=\"\(mimeType)\"/>")
            
            // HTML with Viewport Lock
            let htmlContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <meta name="viewport" content="width=\(width), height=\(height), initial-scale=1.0"/>
                <link rel="stylesheet" type="text/css" href="css/style.css"/>
            </head>
            <body>
                <div class="svg-wrapper">
                    <img src="images/\(newName)" alt="Page \(index + 1)"/>
                </div>
            </body>
            </html>
            """
            
            let htmlName = "page_\(index).xhtml"
            try htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"page_\(index)\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"page_\(index)\" linear=\"yes\"/>")
            
            progressHandler(0.2 + (0.7 * Double(index) / Double(imageURLs.count)))
        }
        
        // 6. Create Metadata (OPF)
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(sourceURL.deletingPathExtension().lastPathComponent)</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
                <meta name="cover" content="img_0"/> </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n"))
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            </manifest>
            <spine>
                \(spineItems.joined(separator: "\n"))
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 7. Navigation (Required)
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc" id="toc"><ol></ol></nav></body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 8. Container XML
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
            if validExts.contains(fileURL.pathExtension.lowercased()) {
                images.append(fileURL)
            }
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
