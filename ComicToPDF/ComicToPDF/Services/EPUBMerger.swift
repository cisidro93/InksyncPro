import Foundation
import UIKit
import ZIPFoundation

struct EPUBMerger {
    
    static func mergeEPUBs(sourceURLs: [URL], outputURL: URL, metadata: PDFMetadata, settings: EPUBSettings, precomputedManifest: EPUBPanelManifest? = nil, onStatusUpdate: ((String) -> Void)? = nil) async throws -> (URL, Int) {
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        
        // 1. CSS
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body { margin: 0; padding: 0; width: 100vw; height: 100vh; background-color: #000000; }
        div.svg-wrapper { width: 100%; height: 100%; margin: 0; padding: 0; text-align: center; }
        img { height: 100%; width: auto; max-width: 100%; object-fit: contain; }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
        var manifestItems: [String] = []
        var spineItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/style.css\" media-type=\"text/css\"/>")
        
        var globalPageIndex = 0
        
        // 2. Process Each EPUB
        for (fileIndex, url) in sourceURLs.enumerated() {
            onStatusUpdate?("Merging file \(fileIndex + 1) of \(sourceURLs.count)...")
            
            // Unzip source
            let sourceTemp = tempDir.appendingPathComponent("source_\(fileIndex)")
            try fileManager.createDirectory(at: sourceTemp, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: url, to: sourceTemp)
            
            // Find images
            let imageURLs = try findImages(in: sourceTemp)
            
            for imgURL in imageURLs {
                let fileExt = imgURL.pathExtension.lowercased()
                // Convert/Copy Image
                let newName = "page_\(String(format: "%05d", globalPageIndex)).jpg"
                let destURL = imagesDir.appendingPathComponent(newName)
                
                // Copy (or re-compress if needed, keeping simple copy for merge)
                if let data = try? Data(contentsOf: imgURL) {
                    try data.write(to: destURL)
                }
                
                // Panel Detection Check
                // ✅ Fix: Correctly access the precomputed manifest using the global index
                var pagesToCreate: [String] = []
                
                // Base Page
                let basePageHTML = generateHTML(title: "Page \(globalPageIndex)", imagePath: "images/\(newName)")
                let basePageName = "page_\(globalPageIndex).xhtml"
                try basePageHTML.write(to: oebpsDir.appendingPathComponent(basePageName), atomically: true, encoding: .utf8)
                
                manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/jpeg\"/>")
                manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"\(basePageName)\" media-type=\"application/xhtml+xml\"/>")
                spineItems.append("<itemref idref=\"page_\(globalPageIndex)\"/>")
                
                // Panels (If manifest exists and settings enabled)
                if settings.splitPanels,
                   let manifest = precomputedManifest,
                   let pageInfo = manifest.pages.first(where: { $0.pageIndex == globalPageIndex }) {
                    
                    // Add Panel Pages (Virtual Zoom)
                    for (pIndex, panel) in pageInfo.panels.enumerated() {
                        let panelName = "page_\(globalPageIndex)_p\(pIndex).xhtml"
                        let panelHTML = generatePanelHTML(imagePath: "images/\(newName)", panel: panel)
                        try panelHTML.write(to: oebpsDir.appendingPathComponent(panelName), atomically: true, encoding: .utf8)
                        
                        manifestItems.append("<item id=\"page_\(globalPageIndex)_p\(pIndex)\" href=\"\(panelName)\" media-type=\"application/xhtml+xml\"/>")
                        spineItems.append("<itemref idref=\"page_\(globalPageIndex)_p\(pIndex)\"/>")
                    }
                }
                
                globalPageIndex += 1
            }
        }
        
        // 3. Navigation
        spineItems.append("<itemref idref=\"nav\" linear=\"no\"/>")
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" hidden="">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc" id="toc" hidden=""><ol hidden=""><li><a href="page_0.xhtml">Start</a></li></ol></nav></body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        
        // 4. OPF
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(metadata.title)</dc:title>
                <dc:creator>\(metadata.author ?? "Unknown")</dc:creator>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
                \(settings.enablePanelView ? "<meta name=\"comic-panel-view\" content=\"enabled\"/>" : "")
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n"))
            </manifest>
            <spine page-progression-direction="\(settings.readingDirection.rawValue)">
                \(spineItems.joined(separator: "\n"))
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 5. Container & Zip
        let metaInfDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        try fileManager.zipItem(at: tempDir, to: outputURL)
        
        return (outputURL, globalPageIndex)
    }
    
    // Helpers
    private static func findImages(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.nameKey]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
        var images: [URL] = []
        let validExts = ["jpg", "jpeg", "png", "webp"]
        while let url = enumerator?.nextObject() as? URL {
            if validExts.contains(url.pathExtension.lowercased()) { images.append(url) }
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    private static func generateHTML(title: String, imagePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>\(title)</title>
            <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
            <link rel="stylesheet" type="text/css" href="css/style.css"/>
        </head>
        <body>
            <div class="svg-wrapper"><img src="\(imagePath)" alt=""/></div>
        </body>
        </html>
        """
    }
    
    private static func generatePanelHTML(imagePath: String, panel: PanelExtractor.Panel) -> String {
        // Calculate viewBox for SVG zooming
        // Assuming 1000x1500 viewport logic for simplicity
        let width = 1000.0
        let height = 1500.0
        let x = panel.boundingBox.minX * width
        // Vision origin (bottom-left) vs SVG/HTML origin (top-left) handling depends on data source.
        // Assuming PanelExtractor data is normalized 0..1 top-left for this context:
        let y = panel.boundingBox.minY * height
        let w = panel.boundingBox.width * width
        let h = panel.boundingBox.height * height
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Panel</title>
            <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
            <link rel="stylesheet" type="text/css" href="css/style.css"/>
            <style>
                /* SVG Crop Technique */
                svg { width: 100vw; height: 100vh; }
            </style>
        </head>
        <body>
            <svg viewBox="\(x) \(y) \(w) \(h)" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg">
                <image width="1000" height="1500" href="\(imagePath)"/>
            </svg>
        </body>
        </html>
        """
    }
}
