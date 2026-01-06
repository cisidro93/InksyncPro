import Foundation
import UIKit
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 1. Unzip
        progressHandler(0.05)
        try fileManager.unzipItem(at: sourceURL, to: tempDir)
        
        // 2. Find Images
        let imageURLs = try findImages(in: tempDir)
        guard !imageURLs.isEmpty else {
            throw NSError(domain: "Conversion", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        
        // 3. Structure
        progressHandler(0.1)
        let epubDir = tempDir.appendingPathComponent("EPUB_Build")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        
        // 4. CSS
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body { margin: 0; padding: 0; width: 100vw; height: 100vh; background-color: #000000; }
        div.svg-wrapper { width: 100%; height: 100%; margin: 0; padding: 0; text-align: center; }
        img { height: 100%; width: auto; max-width: 100%; object-fit: contain; }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
        // 5. Process Images (The Smart Loop)
        var manifestItems: [String] = []
        var spineItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/style.css\" media-type=\"text/css\"/>")
        
        var globalPageIndex = 0
        
        for (sourceIndex, imgURL) in imageURLs.enumerated() {
            // Load Image
            guard let originalImage = UIImage(contentsOfFile: imgURL.path) else { continue }
            
            // Determine "Sub-Pages" (1 if normal, N if splitting)
            var pagesToProcess: [UIImage] = [originalImage]
            
            // ✅ FEATURE: Panel Detection
            if settings.enablePanelSplit {
                // Use the AI Engine we built
                let extracted = try? await PanelExtractor.extractPanels(
                    from: originalImage,
                    mode: settings.epubSettings.panelDetectionMode
                )
                if let panels = extracted, !panels.isEmpty {
                    pagesToProcess = panels
                }
            }
            
            // Process each sub-page (Panel or Full Page)
            for (subIndex, image) in pagesToProcess.enumerated() {
                var finalImage = image
                
                // ✅ FEATURE: Optimization (Resize/Grayscale)
                if settings.optimizeForDevice || settings.imageEnhancement.grayscale {
                    // Temporarily write to disk to pass to processor (simplifies logic)
                    let tempImgURL = tempDir.appendingPathComponent("temp_\(globalPageIndex).jpg")
                    if let data = finalImage.jpegData(compressionQuality: 1.0) {
                        try? data.write(to: tempImgURL)
                        if let processed = ImageProcessor.process(imageURL: tempImgURL, settings: settings) {
                            finalImage = processed
                        }
                    }
                }
                
                // Save Final Image
                let newName = "page_\(String(format: "%04d", globalPageIndex)).jpg"
                let destURL = imagesDir.appendingPathComponent(newName)
                
                if let data = finalImage.jpegData(compressionQuality: settings.compressionQuality.value) {
                    try data.write(to: destURL)
                }
                
                // Manifest & HTML
                let isCover = (globalPageIndex == 0)
                let properties = isCover ? "properties=\"cover-image\"" : ""
                manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/jpeg\" \(properties)/>")
                
                let htmlContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head>
                    <title>Page \(globalPageIndex)</title>
                    <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
                    <link rel="stylesheet" type="text/css" href="css/style.css"/>
                </head>
                <body>
                    <div class="svg-wrapper"><img src="images/\(newName)" alt=""/></div>
                </body>
                </html>
                """
                
                let htmlName = "page_\(globalPageIndex).xhtml"
                try htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
                manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                spineItems.append("<itemref idref=\"page_\(globalPageIndex)\" linear=\"yes\"/>")
                
                globalPageIndex += 1
            }
            
            // Update Progress Bar
            let progress = 0.1 + (0.8 * Double(sourceIndex) / Double(imageURLs.count))
            progressHandler(progress)
        }
        
        // Add Hidden Nav at End
        spineItems.append("<itemref idref=\"nav\" linear=\"no\"/>")
        
        // 6. Metadata
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
        
        // 7. Nav
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" hidden="">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc" id="toc" hidden=""><ol hidden=""><li><a href="page_0.xhtml">Cover</a></li></ol></nav></body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 8. Container & Zip
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        progressHandler(1.0)
        let finalName = sourceURL.deletingPathExtension().lastPathComponent + ".epub"
        let destURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(finalName)
        if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
        try fileManager.zipItem(at: epubDir, to: destURL)
        
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
