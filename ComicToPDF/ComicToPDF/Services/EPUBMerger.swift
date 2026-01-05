
import Foundation
import UIKit
import ZIPFoundation

class EPUBMerger {
    
    static func mergeEPUBs(sourceURLs: [URL], outputURL: URL, metadata: PDFMetadata, settings: EPUBSettings, precomputedManifest: EPUBPanelManifest? = nil, onStatusUpdate: ((String) -> Void)? = nil) async throws -> (URL, Int) {
        
        print("🔄 Starting EPUB merge/generation...")
        onStatusUpdate?("Preparing EPUB structure...")
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("EPUBGen_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 1. Setup Standard Directory Structure
        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        let metaInfDir = tempDir.appendingPathComponent("META-INF")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 2. Create Mimetype and Container
        try "application/epub+zip".write(to: tempDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 3. Extract and Organize Images
        onStatusUpdate?("Processing images...")
        var finalImageFiles: [String] = []
        var totalPageCount = 0
        
        for (index, url) in sourceURLs.enumerated() {
            let ext = url.pathExtension.lowercased()
            
            if ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) {
                // Handle Raw Image
                totalPageCount += 1
                let newName = String(format: "page%04d.%@", totalPageCount, ext)
                let destURL = imagesDir.appendingPathComponent(newName)
                try fileManager.copyItem(at: url, to: destURL)
                finalImageFiles.append(newName)
            } else {
                // Handle Archive/EPUB
                let extractTemp = tempDir.appendingPathComponent("extract_\(index)")
                try fileManager.createDirectory(at: extractTemp, withIntermediateDirectories: true)
                try fileManager.unzipItem(at: url, to: extractTemp)
                
                let enumerator = fileManager.enumerator(at: extractTemp, includingPropertiesForKeys: nil)
                var foundImages: [URL] = []
                
                while let fileURL = enumerator?.nextObject() as? URL {
                    if ["jpg", "jpeg", "png", "webp"].contains(fileURL.pathExtension.lowercased()) {
                        foundImages.append(fileURL)
                    }
                }
                foundImages.sort { $0.path < $1.path }
                
                for imgURL in foundImages {
                    totalPageCount += 1
                    let newName = String(format: "page%04d.%@", totalPageCount, imgURL.pathExtension)
                    let destURL = imagesDir.appendingPathComponent(newName)
                    try fileManager.copyItem(at: imgURL, to: destURL)
                    finalImageFiles.append(newName)
                }
                
                // ✅ FIX: Delete the temp extraction folder so it doesn't get zipped up!
                try? fileManager.removeItem(at: extractTemp)
            }
        }
        
        if finalImageFiles.isEmpty {
            throw NSError(domain: "EPUBGen", code: 404, userInfo: [NSLocalizedDescriptionKey: "No images found in source files."])
        }
        
        // 4. Generate HTML Pages (XHTML)
        onStatusUpdate?("Creating pages...")
        
        var spineItems = ""
        var manifestItems = ""
        var ncxNavPoints = ""
        var finalPageCount = 0
        
        // Helper to write a page to disk and add to manifest/spine
        func writePage(imageFilename: String, title: String, isFullPage: Bool) throws {
            finalPageCount += 1
            let pageID = "page\(String(format: "%04d", finalPageCount))"
            let imgID = "img\(String(format: "%04d", finalPageCount))"
            let pageFile = "\(pageID).xhtml"
            
            let html = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>\(title)</title>
                <meta name="viewport" content="width=device-width, initial-scale=1.0" />
                <style>
                    body { margin:0; padding:0; background:black; height:100vh; display:flex; justify-content:center; align-items:center; }
                    img { max-width:100%; max-height:100%; object-fit:contain; }
                </style>
            </head>
            <body>
                <div class="page">
                    <img src="../images/\(imageFilename)" alt="\(title)" />
                </div>
            </body>
            </html>
            """
            
            try html.write(to: textDir.appendingPathComponent(pageFile), atomically: true, encoding: .utf8)
            
            let mime = imageFilename.hasSuffix("png") ? "image/png" : "image/jpeg"
            
            manifestItems += """
            <item id="\(pageID)" href="text/\(pageFile)" media-type="application/xhtml+xml"/>
            <item id="\(imgID)" href="images/\(imageFilename)" media-type="\(mime)"/>
            """
            spineItems += "<itemref idref=\"\(pageID)\"/>\n"
            
            // Add to Table of Contents (only for full pages to keep it clean)
            if isFullPage {
                ncxNavPoints += """
                <navPoint id="nav\(finalPageCount)" playOrder="\(finalPageCount)">
                    <navLabel><text>\(title)</text></navLabel>
                    <content src="text/\(pageFile)"/>
                </navPoint>
                """
            }
        }
        
        // Main Loop
        for (index, imageFilename) in finalImageFiles.enumerated() {
            let pageNum = index + 1
            
            // 1. Add the Full Page
            try writePage(imageFilename: imageFilename, title: "Page \(pageNum)", isFullPage: true)
            
            // 2. Kindle Optimization: Physical Panel Splitting
            if settings.splitPanels,
               let panels = precomputedManifest?.pages.first(where: { $0.pageNumber == pageNum })?.panels {
                
                // Load the full image to crop it
                let imageURL = imagesDir.appendingPathComponent(imageFilename)
                if let imageData = try? Data(contentsOf: imageURL),
                   let uiImage = UIImage(data: imageData),
                   let cgImage = uiImage.cgImage {
                    
                    let width = CGFloat(cgImage.width)
                    let height = CGFloat(cgImage.height)
                    
                    for (pIndex, panel) in panels.enumerated() {
                        // Convert normalized coords (0-1) to pixels
                        let cropRect = CGRect(
                            x: panel.x * width,
                            y: panel.y * height,
                            width: panel.width * width,
                            height: panel.height * height
                        )
                        
                        if let croppedCG = cgImage.cropping(to: cropRect) {
                            let croppedImage = UIImage(cgImage: croppedCG)
                            let panelFilename = "p\(pageNum)_panel\(pIndex).jpg"
                            
                            // Save Panel Image
                            if let panelData = croppedImage.jpegData(compressionQuality: 0.7) { // 0.7 is Kindle Sweet Spot
                                try panelData.write(to: imagesDir.appendingPathComponent(panelFilename))
                                
                                // Add Panel as a new Page
                                try writePage(imageFilename: panelFilename, title: "Page \(pageNum) - Panel \(pIndex + 1)", isFullPage: false)
                            }
                        }
                    }
                }
            }
        }
        
        // 5. Generate OPF (Manifest & Spine)
        onStatusUpdate?("Finalizing metadata...")
        
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="pub-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(metadata.title)</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
            \(settings.enablePanelView ? "<meta name=\"comic-panel-view\" content=\"enabled\"/>" : "")
          </metadata>
          <manifest>
            \(manifestItems)
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          </manifest>
          <spine toc="ncx">
            \(spineItems)
          </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 6. Generate NCX (TOC)
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:12345"/></head>
            <docTitle><text>\(metadata.title)</text></docTitle>
            <navMap>
                <navPoint id="nav1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 7. Zip it up
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        // FIX: Use modern ZIPFoundation init
        let archive = try Archive(url: outputURL, accessMode: .create)
        
        try archive.addEntry(with: "mimetype", relativeTo: tempDir, compressionMethod: .none)
        
        for subpath in try fileManager.subpathsOfDirectory(atPath: tempDir.path) {
            if subpath == "mimetype" { continue }
            try archive.addEntry(with: subpath, relativeTo: tempDir, compressionMethod: .deflate)
        }
        
        print("✅ EPUB Generated Successfully at \(outputURL.path)")
        return (outputURL, totalPageCount)
    }
}
