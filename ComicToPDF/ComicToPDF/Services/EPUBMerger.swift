import Foundation
import UIKit
import ZIPFoundation

// ============================================================================
// MARK: - EPUB MERGER
// ============================================================================

class EPUBMerger {
    
    /// Merges multiple EPUB files into a single EPUB.
    /// - Parameters:
    ///   - sourceURLs: List of EPUB URLs to merge.
    ///   - outputURL: Destination URL for the merged EPUB.
    ///   - metadata: Metadata for the new EPUB.
    ///   - settings: Settings for EPUB generation.
    /// - Returns: The URL of the merged EPUB and the total page count.
    static func mergeEPUBs(sourceURLs: [URL], outputURL: URL, metadata: PDFMetadata, settings: EPUBSettings) async throws -> (URL, Int) {
        
        print("🔄 Starting EPUB merge for \(sourceURLs.count) files")
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBMerge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Create EPUB structure
        let epubDir = tempDir.appendingPathComponent("epub")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        for dir in [epubDir, metaInfDir, oebpsDir, imagesDir, textDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        
        // Write mimetype
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        
        // Write container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // Write CSS
        let cssContent = """
        @charset "UTF-8";
        * { margin: 0; padding: 0; border: 0; }
        html, body { 
            width: 100%; 
            height: 100%; 
            margin: 0; 
            padding: 0; 
            background-color: #000;
            overflow: hidden;
        }
        .page { 
            width: 100vw; 
            height: 100vh; 
            display: flex; 
            align-items: center; 
            justify-content: center;
            overflow: hidden;
        }
        img { 
            max-width: 100%; 
            max-height: 100%; 
            object-fit: contain;
        }
        """
        try cssContent.write(to: oebpsDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
        var pageNumber = 1
        var manifestItems: [String] = []
        var spineItems: [String] = []
        
        // Process each source EPUB
        for (index, sourceURL) in sourceURLs.enumerated() {
            print("📖 Processing EPUB \(index + 1)/\(sourceURLs.count): \(sourceURL.lastPathComponent)")
            
            let workingDir = tempDir.appendingPathComponent("source_\(index)")
            try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
            
            // Unzip
            try FileManager.default.unzipItem(at: sourceURL, to: workingDir)
            print("   ✓ Unzipped to \(workingDir.path)")
            
            // Try multiple possible image directory locations
            var sourceImagesDir: URL? = nil
            let possiblePaths = [
                "OEBPS/images",
                "OPS/images", 
                "EPUB/images",
                "images",
                "OEBPS/Images",
                "content/images"
            ]
            
            for path in possiblePaths {
                let testDir = workingDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: testDir.path) {
                    sourceImagesDir = testDir
                    print("   ✓ Found images in: \(path)")
                    break
                }
            }
            
            // If standard paths don't work, search recursively
            if sourceImagesDir == nil {
                print("   ⚠️ Standard paths not found, searching recursively...")
                sourceImagesDir = findImagesDirectory(in: workingDir)
            }
            
            guard let imagesDirectory = sourceImagesDir else {
                print("   ❌ ERROR: No images found in EPUB \(index + 1)")
                throw NSError(domain: "EPUBMerger", code: 404, 
                             userInfo: [NSLocalizedDescriptionKey: "No images found in \(sourceURL.lastPathComponent)"])
            }
            
            // Get all image files
            let imageFiles = try FileManager.default.contentsOfDirectory(
                at: imagesDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains(ext)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            print("   ✓ Found \(imageFiles.count) images")
            
            if imageFiles.isEmpty {
                print("   ⚠️ WARNING: Images directory exists but contains no images")
                continue
            }
            
            // Copy each image
            for (imgIndex, imageURL) in imageFiles.enumerated() {
                let ext = imageURL.pathExtension
                let destImageName = "page\(pageNumber).\(ext)"
                let destImageURL = imagesDir.appendingPathComponent(destImageName)
                
                // DIRECT COPY - NO PROCESSING
                do {
                    try FileManager.default.copyItem(at: imageURL, to: destImageURL)
                    
                    // Verify file was copied
                    let attrs = try FileManager.default.attributesOfItem(atPath: destImageURL.path)
                    let size = attrs[.size] as? Int64 ?? 0
                    
                    if imgIndex == 0 || imgIndex == imageFiles.count - 1 {
                        print("      Page \(pageNumber): \(destImageName) (\(size) bytes)")
                    }
                } catch {
                    print("   ❌ ERROR copying \(imageURL.lastPathComponent): \(error)")
                    throw error
                }
                
                // Media type
                let mediaType: String
                switch ext.lowercased() {
                case "png": mediaType = "image/png"
                case "gif": mediaType = "image/gif"
                case "webp": mediaType = "image/webp"
                default: mediaType = "image/jpeg"
                }
                
                // Manifest
                manifestItems.append("""
                    <item id="image\(pageNumber)" href="images/\(destImageName)" media-type="\(mediaType)"/>
                """)
                
                // XHTML
                let xhtmlFileName = "page\(pageNumber).xhtml"
                let xhtmlContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head>
                    <title>Page \(pageNumber)</title>
                    <link rel="stylesheet" type="text/css" href="../style.css"/>
                    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
                </head>
                <body>
                    <div class="page">
                        <img src="../images/\(destImageName)" alt="Page \(pageNumber)"/>
                    </div>
                </body>
                </html>
                """
                try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlFileName), atomically: true, encoding: .utf8)
                
                manifestItems.append("""
                    <item id="page\(pageNumber)" href="text/\(xhtmlFileName)" media-type="application/xhtml+xml"/>
                """)
                
                spineItems.append("""
                    <itemref idref="page\(pageNumber)"/>
                """)
                
                pageNumber += 1
            }
        }
        
        let totalPages = pageNumber - 1
        print("📊 Total pages merged: \(totalPages)")
        
        if totalPages == 0 {
            throw NSError(domain: "EPUBMerger", code: 500,
                         userInfo: [NSLocalizedDescriptionKey: "No images were found in any EPUB files"])
        }
        
        // Create content.opf
        let bookTitle = metadata.title.isEmpty ? "Merged Book" : metadata.title
        let bookAuthor = metadata.author.isEmpty ? "Unknown" : metadata.author
        let bookID = UUID().uuidString
        
        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookID">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">\(bookID)</dc:identifier>
                <dc:title>\(bookTitle)</dc:title>
                <dc:creator>\(bookAuthor)</dc:creator>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
        \(manifestItems.joined(separator: "\n"))
            </manifest>
            <spine toc="ncx">
        \(spineItems.joined(separator: "\n"))
            </spine>
        </package>
        """
        try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // Create toc.ncx
        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="\(bookID)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
            </head>
            <docTitle>
                <text>\(bookTitle)</text>
            </docTitle>
            <navMap>
                <navPoint id="navpoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page1.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try tocNCX.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // Create archive
        print("📦 Creating EPUB archive...")
        let finalEPUB = tempDir.appendingPathComponent("\(bookTitle).epub")
        
        guard let archive = Archive(url: finalEPUB, accessMode: .create) else {
            throw NSError(domain: "EPUBMerger", code: 500,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create archive"])
        }
        
        // Add mimetype first (uncompressed)
        try archive.addEntry(with: "mimetype", relativeTo: epubDir, compressionMethod: .none)
        
        // Add all other files
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: epubDir.path)
        for file in allFiles where file != "mimetype" {
            try archive.addEntry(with: file, relativeTo: epubDir, compressionMethod: .deflate)
        }
        
        // Check final file size
        let finalAttrs = try FileManager.default.attributesOfItem(atPath: finalEPUB.path)
        let finalSize = finalAttrs[.size] as? Int64 ?? 0
        print("✅ EPUB created: \(ByteCountFormatter.string(fromByteCount: finalSize, countStyle: .file))")
        
        // Move to destination
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: finalEPUB, to: outputURL)
        
        print("✅ Merge complete! \(totalPages) pages")
        return (outputURL, totalPages)
    }
    
    // Helper function to find images directory recursively
    private static func findImagesDirectory(in rootURL: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory else {
                continue
            }
            
            if isDirectory && fileURL.lastPathComponent.lowercased() == "images" {
                // Check if it actually contains images
                if let contents = try? fm.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil),
                   contents.contains(where: { ["jpg", "jpeg", "png", "gif", "webp"].contains($0.pathExtension.lowercased()) }) {
                    return fileURL
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Extraction Logic
    
    private static func extractOrderedImages(from rootURL: URL) throws -> [URL] {
        // 1. Find OEBPS/content.opf
        // Look for META-INF/container.xml first
        let containerURL = rootURL.appendingPathComponent("META-INF/container.xml")
        
        var opfPath = "OEBPS/content.opf" // Default
        
        if FileManager.default.fileExists(atPath: containerURL.path),
           let data = try? Data(contentsOf: containerURL),
           let content = String(data: data, encoding: .utf8) {
            // Simple regex to find full-path
            let pattern = "full-path=\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                if let range = Range(match.range(at: 1), in: content) {
                    opfPath = String(content[range])
                }
            }
        }
        
        let opfURL = rootURL.appendingPathComponent(opfPath)
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            // Fallback: just search for images recursively if OPF structure fails
            return try getAllImagesRecursively(from: rootURL)
        }
        
        // 2. Parse OPF to get Manifest and Spine
        let opfParser = OPFParser(url: opfURL)
        guard let spineBase = opfParser.parse() else {
             return try getAllImagesRecursively(from: rootURL)
        }
        
        // 3. Walk Spine to get XHTMLs -> Images
        var orderedImages: [URL] = []
        let opfDir = opfURL.deletingLastPathComponent()
        
        for itemRef in spineBase.spine {
            if let href = spineBase.manifest[itemRef] {
                let xhtmlURL = opfDir.appendingPathComponent(href)
                let imagesInPage = try extractImagesFromXHTML(at: xhtmlURL)
                orderedImages.append(contentsOf: imagesInPage)
            }
        }
        
        if orderedImages.isEmpty {
             return try getAllImagesRecursively(from: rootURL)
        }
        
        return orderedImages
    }
    
    private static func extractImagesFromXHTML(at url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url) else { return [] }
        
        // Regex for <img src="...">
        let pattern = "<img[^>]+src=\"([^\"]+)\""
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        
        var images: [URL] = []
        let baseDir = url.deletingLastPathComponent()
        
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let src = String(content[range])
                // Handle relative paths
                let imageURL = baseDir.appendingPathComponent(src).standardized
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    images.append(imageURL)
                }
            }
        }
        
        return images
    }
    
    private static func getAllImagesRecursively(from url: URL) throws -> [URL] {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        var images: [URL] = []
        
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if imageExtensions.contains(fileURL.pathExtension.lowercased()) {
                    // Ignore thumbnails or cover if they duplicate others? No, keep all for now.
                    // Filter out some system files
                    if !fileURL.lastPathComponent.hasPrefix(".") {
                        images.append(fileURL)
                    }
                }
            }
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Mini OPF Parser

class OPFParser: NSObject, XMLParserDelegate {
    let url: URL
    var manifest: [String: String] = [:] // id -> href
    var spine: [String] = [] // idrefs
    
    private var inManifest = false
    private var inSpine = false
    
    init(url: URL) {
        self.url = url
        super.init()
    }
    
    func parse() -> (manifest: [String: String], spine: [String])? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        parser.delegate = self
        if parser.parse() {
            return (manifest, spine)
        }
        return nil
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "manifest" { inManifest = true }
        if elementName == "spine" { inSpine = true }
        
        if inManifest && elementName == "item" {
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
            }
        }
        
        if inSpine && elementName == "itemref" {
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "manifest" { inManifest = false }
        if elementName == "spine" { inSpine = false }
    }
}
