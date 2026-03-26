import Foundation
import UIKit
import ZIPFoundation

class EPUBMerger {
    
    // Merge multiple EPUBs into a single omnibus EPUB
    func mergeEPUBs(sourceURLs: [URL], outputURL: URL, settings: ConversionSettings, overrideCoverData: Data? = nil) async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 1. Structure
        let epubDir = tempDir.appendingPathComponent("EPUB_Merge")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        
        // 2. CSS
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
        
        // 2.5 Inject Override Cover if Present
        if let coverData = overrideCoverData {
            let coverName = "page_00000_cover.jpg"
            let destURL = imagesDir.appendingPathComponent(coverName)
            try? coverData.write(to: destURL)
            
            let htmlName = "page_00000_cover.xhtml"
            let htmlContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Cover</title>
                <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
                <link rel="stylesheet" type="text/css" href="css/style.css"/>
            </head>
            <body>
                <div class="svg-wrapper"><img src="images/\(coverName)" alt="Cover"/></div>
            </body>
            </html>
            """
            try? htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"cover_page\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
            manifestItems.append("<item id=\"cover_img\" href=\"images/\(coverName)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
            spineItems.append("<itemref idref=\"cover_page\" linear=\"yes\"/>")
            
            globalPageIndex += 1
        }
        
        // 3. Process Each EPUB
        for (index, url) in sourceURLs.enumerated() {
            let unzipDir = tempDir.appendingPathComponent("unzip_\(index)")
            try fileManager.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: url, to: unzipDir)
            
            // Extract Images (Assuming standard OEBPS/images structure or recursive search)
            let foundImages = try findImages(in: unzipDir)
            
            for imgURL in foundImages {
                let newName = "page_\(String(format: "%05d", globalPageIndex)).jpg"
                let destURL = imagesDir.appendingPathComponent(newName)
                
                // Copy/Re-compress
                if let data = try? Data(contentsOf: imgURL) {
                    try data.write(to: destURL)
                }
                
                // Manifest & HTML
                let htmlName = "page_\(String(format: "%05d", globalPageIndex)).xhtml"
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
                
                try htmlContent.write(to: oebpsDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
                
                manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/jpeg\"/>")
                spineItems.append("<itemref idref=\"page_\(globalPageIndex)\" linear=\"yes\"/>")
                
                globalPageIndex += 1
            }
        }
        
        spineItems.append("<itemref idref=\"nav\" linear=\"no\"/>")
        
        // 4. Metadata (OPF)
        // ✅ Fix: Use 'includeFullPage' instead of legacy 'enablePanelView'
        // ✅ Fix: Use explicit String.Encoding.utf8
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Merged Comic Collection</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(Date().ISO8601Format())</meta>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n"))
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            </manifest>
            <spine \(settings.mangaMode ? "page-progression-direction=\"rtl\"" : "")>
                \(spineItems.joined(separator: "\n"))
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: String.Encoding.utf8)
        
        // 5. Nav
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Navigation</title></head>
        <body><nav epub:type="toc" id="toc"><ol><li><a href="page_00000.xhtml">Start</a></li></ol></nav></body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: String.Encoding.utf8)
        
        // 6. Zip
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: String.Encoding.utf8)
        
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        
        guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
            throw NSError(domain: "EPUBMerger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate ZIP stream"])
        }
        
        // 7. Critical: Inject IDPF Valid Uncompressed Mimetype File
        let mimetypePath = epubDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
        try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
        
        // 8. Recursive Payload Addition
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
        if let enumerator = fileManager.enumerator(at: epubDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.lastPathComponent == "mimetype" { continue }
                
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                if isDirectory.boolValue { continue }
                
                let relativePath = fileURL.path.replacingOccurrences(of: epubDir.path + "/", with: "")
                let ext = fileURL.pathExtension.lowercased()
                let compression: CompressionMethod = ["jpg", "jpeg", "png", "webp"].contains(ext) ? .none : .deflate
                
                try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: compression)
            }
        }
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

