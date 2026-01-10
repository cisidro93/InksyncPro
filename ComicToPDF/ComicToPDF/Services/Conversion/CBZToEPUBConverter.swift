import SwiftUI
import ZIPFoundation

class CBZToEPUBConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, manualManifest: [Int: [PanelExtractor.Panel]]?, progress: @escaping (Double) -> Void) async throws -> [URL] {
        
        // ✅ RESTORED: Define fileManager at the top scope
        let fileManager = FileManager.default
        
        // 1. Safe Extraction (Using ZipUtilities)
        progress(0.1)
        
        // Use the safe extractor
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        let tempDir = extractionResult.workingDir
        let imageFiles = extractionResult.imageURLs.map { $0.lastPathComponent }
        
        // ZipUtilities creates the tempDir, so we must ensure it gets cleaned up later.
        // We use a specific defer block for this extraction folder.
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 2. Verify Images Found
        guard !imageFiles.isEmpty else { 
            throw NSError(domain: "Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"]) 
        }
        
        // 3. Setup EPUB Structure
        let epubDir = tempDir.appendingPathComponent("EPUB_Build")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 4. Create Mimetype & Container
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        
        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 5. Process Pages
        var spineItems: [String] = []
        var manifestItems: [String] = []
        
        for (index, imageName) in imageFiles.enumerated() {
            // Note: The file is already at extractionResult.imageURLs[index], 
            // but we need to move/copy it into the EPUB structure.
            let srcURL = extractionResult.imageURLs[index]
            
            let ext = srcURL.pathExtension.lowercased()
            let safeExt = ext == "jpg" ? "jpeg" : ext
            let newImageName = String(format: "image_%04d.%@", index + 1, ext)
            let destURL = imagesDir.appendingPathComponent(newImageName)
            
            try fileManager.copyItem(at: srcURL, to: destURL)
            
            // Get Panels for this specific page (if any)
            var pagePanels = manualManifest?[index] ?? []
            
            // ✅ AUTO-DETECT FALLBACK
            // If we have no manual panels, but panel splitting is ON, we must detect them now.
            if pagePanels.isEmpty && settings.enablePanelSplit {
                if let image = UIImage(contentsOfFile: destURL.path) {
                    // Use mangaMode from settings if applicable, or default false
                    // actually settings has mangaMode
                    pagePanels = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: settings.mangaMode)
                }
            }
            
            // Create HTML for Page (With Guided View Metadata)
            let xhtmlContent = generateXHTML(imageName: newImageName, title: "Page \(index + 1)", panels: pagePanels)
            
            let xhtmlName = String(format: "page_%04d.xhtml", index + 1)
            try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
            
            // Add to manifest
            manifestItems.append("<item id=\"img_\(index+1)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\"/>")
            manifestItems.append("<item id=\"page_\(index+1)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\" properties=\"svg\"/>")
            spineItems.append("<itemref idref=\"page_\(index+1)\"/>")
            
            progress(0.2 + (0.7 * Double(index) / Double(imageFiles.count)))
        }
        
        // 6. Create OPF (Metadata)
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(sourceURL.deletingPathExtension().lastPathComponent)</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
                <meta name="fixed-layout" content="true"/>
                <meta name="original-resolution" content="1920x2560"/> 
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine toc="ncx">
                \(spineItems.joined(separator: "\n        "))
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 7. Create TOC (Required for legacy)
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:12345"/></head>
            <docTitle><text>Comic</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page_0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 8. Zip it up
        let outputFilename = sourceURL.deletingPathExtension().lastPathComponent + ".epub"
        let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        
        try fileManager.zipItem(at: epubDir, to: outputURL)
        
        // Cleanup (The deferred cleanup at step 1 handles the tempDir)
        progress(1.0)
        
        return [outputURL]
    }
    
    // ✅ OPTION B IMPLEMENTATION: CSS-Based Region Magnification
    private func generateXHTML(imageName: String, title: String, panels: [PanelExtractor.Panel]) -> String {
        
        // 1. Generate Target Divs for each Panel
        var panelDivs = ""
        
        if !panels.isEmpty {
            for (i, panel) in panels.enumerated() {
                // Convert 0.0-1.0 coords to percentages
                let top = String(format: "%.2f", panel.boundingBox.minY * 100)
                let left = String(format: "%.2f", panel.boundingBox.minX * 100)
                let width = String(format: "%.2f", panel.boundingBox.width * 100)
                let height = String(format: "%.2f", panel.boundingBox.height * 100)
                
                // Standard AMZN Region Magnification Class Structure
                panelDivs += """
                <div id="panel-\(i+1)" class="app-amzn-magnify" data-app-amzn-magnify="{
                    \\"targetId\\": \\"panel-target-\(i+1)\\",
                    \\"ordinal\\": \(i+1)
                }" style="position: absolute; top: \(top)%; left: \(left)%; width: \(width)%; height: \(height)%;">
                </div>
                """
            }
        }
        
        // 2. Wrap it all in the XHTML
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
            <title>\(title)</title>
            <meta name="viewport" content="width=100%, height=100%"/>
            <style type="text/css">
                body { margin: 0; padding: 0; background-color: #000; width: 100vw; height: 100vh; overflow: hidden; }
                .page-container { position: relative; width: 100%; height: 100%; }
                img { width: 100%; height: 100%; object-fit: contain; }
                /* Region Magnification Targets (Invisible to naked eye, seen by Kindle) */
                .app-amzn-magnify { border: 1px solid rgba(0,0,0,0); z-index: 10; cursor: pointer; }
            </style>
        </head>
        <body>
            <div class="page-container">
                <img src="../images/\(imageName)" alt="comic page"/>
                \(panelDivs)
            </div>
        </body>
        </html>
        """
    }
}
