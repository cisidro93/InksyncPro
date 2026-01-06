import Foundation
import UIKit
import ZIPFoundation // Ensure this package is added to your project

class CBZToEPUBConverter {
    
    // The main function that does the work
    func convert(sourceURL: URL, settings: EPUBSettings, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer { try? fileManager.removeItem(at: tempDir) } // Cleanup when done
        
        // 1. Unzip the CBZ
        progressHandler(0.1)
        try fileManager.unzipItem(at: sourceURL, to: tempDir)
        
        // 2. Find all Images
        let imageURLs = try findImages(in: tempDir)
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "Conversion", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found in archive"])
        }
        
        // 3. Create EPUB Structure
        progressHandler(0.3)
        let epubDir = tempDir.appendingPathComponent("EPUB_Build")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        
        // 4. Process & Move Images
        var manifestItems: [String] = []
        var spineItems: [String] = []
        
        for (index, imgURL) in imageURLs.enumerated() {
            let newName = "page_\(String(format: "%03d", index + 1)).jpg"
            let destURL = imagesDir.appendingPathComponent(newName)
            
            // Move file
            try fileManager.moveItem(at: imgURL, to: destURL)
            
            // Add to EPUB Manifest
            manifestItems.append("<item id=\"img_\(index)\" href=\"images/\(newName)\" media-type=\"image/jpeg\"/>")
            
            // Create HTML Page for this image
            let htmlContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Page \(index + 1)</title><meta name="viewport" content="width=device-width, initial-scale=1.0"/></head>
            <body style="margin:0;padding:0;text-align:center;">
                <img src="images/\(newName)" style="height:100%;max-width:100%;"/>
            </body>
            </html>
            """
            
            let htmlName = "page_\(index).xhtml"
            try htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"page_\(index)\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"page_\(index)\"/>")
            
            // Update Progress
            let current = 0.3 + (0.6 * Double(index) / Double(imageURLs.count))
            progressHandler(current)
        }
        
        // 5. Create content.opf (The Metadata)
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(sourceURL.deletingPathExtension().lastPathComponent)</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
            </metadata>
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
        
        // 6. Create required container.xml
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        let containerContent = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerContent.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 7. Create basic nav.xhtml
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc" id="toc"><ol></ol></nav></body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 8. Zip it all up
        progressHandler(0.95)
        let finalName = sourceURL.deletingPathExtension().lastPathComponent + ".epub"
        let destURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(finalName)
        
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        
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
