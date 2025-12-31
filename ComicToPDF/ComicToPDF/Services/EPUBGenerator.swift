import Foundation
import UIKit
import ZIPFoundation

// =============================================================================
// MARK: - EPUB GENERATOR CLASS
// =============================================================================

class EPUBGenerator {
    
    private let tempDirectory: URL
    private let settings: EPUBSettings
    private let metadata: PDFMetadata
    
    init(settings: EPUBSettings, metadata: PDFMetadata) {
        self.settings = settings
        self.metadata = metadata
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBGeneration_\(UUID().uuidString)", isDirectory: true)
    }
    
    // MARK: - Main Generation Function
    
    func generateEPUB(from images: [UIImage], outputName: String) async throws -> URL {
        try createEPUBStructure()
        try await generateContent(from: images)
        try generateMetadataFiles()
        let epubURL = try packageEPUB(outputName: outputName)
        cleanup()
        return epubURL
    }
    
    // MARK: - EPUB Structure Creation
    
    private func createEPUBStructure() throws {
        // Create EPUB directory structure
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("OEBPS/images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("OEBPS/text"), withIntermediateDirectories: true)
        
        // Create mimetype file (must be first, uncompressed)
        let mimetypeURL = tempDirectory.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypeURL, atomically: true, encoding: .utf8)
        
        // Create META-INF/container.xml
        try generateContainerXML()
    }
    
    private func generateContainerXML() throws {
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        
        let containerURL = tempDirectory.appendingPathComponent("META-INF/container.xml")
        try containerXML.write(to: containerURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Content Generation
    
    private func generateContent(from images: [UIImage]) async throws {
        // Process and save images
        for (index, image) in images.enumerated() {
            let imageData = image.jpegData(compressionQuality: 0.9) ?? Data()
            let imageURL = tempDirectory.appendingPathComponent("OEBPS/images/page\(index + 1).jpg")
            try imageData.write(to: imageURL)
            
            // Create XHTML page for each image
            try generateImagePage(index: index, totalPages: images.count)
        }
        
        // Generate table of contents
        if settings.includeTableOfContents {
            try generateTableOfContents(pageCount: images.count)
        }
    }
    
    private func generateImagePage(index: Int, totalPages: Int) throws {
        let pageNumber = index + 1
        let imageWidth = 800  // Standard comic width
        let imageHeight = 1200  // Standard comic height
        
        let xhtmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Page \(pageNumber)</title>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
            <meta name="viewport" content="width=\(imageWidth), height=\(imageHeight)"/>
            <style type="text/css">
                body { margin: 0; padding: 0; text-align: center; }
                .page { width: 100%; height: 100vh; display: flex; align-items: center; justify-content: center; }
                img { max-width: 100%; max-height: 100%; object-fit: contain; }
            </style>
        </head>
        <body>
            <div class="page">
                <img src="../images/page\(pageNumber).jpg" alt="Page \(pageNumber)"/>
            </div>
        </body>
        </html>
        """
        
        let pageURL = tempDirectory.appendingPathComponent("OEBPS/text/page\(pageNumber).xhtml")
        try xhtmlContent.write(to: pageURL, atomically: true, encoding: .utf8)
    }
    
    private func generateTableOfContents(pageCount: Int) throws {
        let tocContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Table of Contents</title>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
        </head>
        <body>
            <h1>Table of Contents</h1>
            <nav>
                <ol>
        \(generateTOCEntries(pageCount: pageCount))
                </ol>
            </nav>
        </body>
        </html>
        """
        
        let tocURL = tempDirectory.appendingPathComponent("OEBPS/text/toc.xhtml")
        try tocContent.write(to: tocURL, atomically: true, encoding: .utf8)
    }
    
    private func generateTOCEntries(pageCount: Int) -> String {
        return (1...pageCount).map { pageNumber in
            "                    <li><a href=\"page\(pageNumber).xhtml\">Page \(pageNumber)</a></li>"
        }.joined(separator: "\n")
    }
    
    // MARK: - Metadata Files Generation
    
    private func generateMetadataFiles() throws {
        try generateContentOPF()
        try generateTocNCX()
    }
    
    private func generateContentOPF() throws {
        let pageCount = try FileManager.default.contentsOfDirectory(at: tempDirectory.appendingPathComponent("OEBPS/images"), includingPropertiesForKeys: nil).count
        
        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:identifier id="BookID">\(UUID().uuidString)</dc:identifier>
                <dc:title>\(metadata.title.isEmpty ? "Comic Book" : metadata.title)</dc:title>
                <dc:creator>\(metadata.author.isEmpty ? "Unknown" : metadata.author)</dc:creator>
                <dc:language>en</dc:language>
                <dc:description>\(metadata.summary.isEmpty ? "Comic book converted from CBZ/CBR" : metadata.summary)</dc:description>
                <dc:publisher>\(metadata.publisher.isEmpty ? "ComicToPDF" : metadata.publisher)</dc:publisher>
                <dc:date>\(ISO8601DateFormatter().string(from: Date()))</dc:date>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta name="cover" content="cover-image"/>
            </metadata>
            <manifest>
                <item id="cover-image" href="images/page1.jpg" media-type="image/jpeg" properties="cover-image"/>
                <item id="toc" href="text/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(generateManifestItems(pageCount: pageCount))
            </manifest>
            <spine page-progression-direction="\(settings.readingDirection.rawValue)">
        \(generateSpineItems(pageCount: pageCount))
            </spine>
        </package>
        """
        
        let contentURL = tempDirectory.appendingPathComponent("OEBPS/content.opf")
        try contentOPF.write(to: contentURL, atomically: true, encoding: String.Encoding.utf8)
    }
    
    private func generateManifestItems(pageCount: Int) -> String {
        var items: [String] = []
        
        // Add image items
        for pageNumber in 1...pageCount {
            items.append("                <item id=\"image\(pageNumber)\" href=\"images/page\(pageNumber).jpg\" media-type=\"image/jpeg\"/>")
            items.append("                <item id=\"page\(pageNumber)\" href=\"text/page\(pageNumber).xhtml\" media-type=\"application/xhtml+xml\"/>")
        }
        
        return items.joined(separator: "\n")
    }
    
    private func generateSpineItems(pageCount: Int) -> String {
        let items = (1...pageCount).map { pageNumber in
            "                <itemref idref=\"page\(pageNumber)\"/>"
        }
        return items.joined(separator: "\n")
    }
    
    private func generateTocNCX() throws {
        // Generate legacy NCX file for older readers
        let pageCount = try FileManager.default.contentsOfDirectory(at: tempDirectory.appendingPathComponent("OEBPS/images"), includingPropertiesForKeys: nil).count
        
        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
            <head>
                <meta name="dtb:uid" content="\(UUID().uuidString)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pageCount)"/>
                <meta name="dtb:maxPageNumber" content="\(pageCount)"/>
            </head>
            <docTitle>
                <text>\(metadata.title.isEmpty ? "Comic Book" : metadata.title)</text>
            </docTitle>
            <navMap>
        \(generateNCXNavPoints(pageCount: pageCount))
            </navMap>
        </ncx>
        """
        
        let ncxURL = tempDirectory.appendingPathComponent("OEBPS/toc.ncx")
        try tocNCX.write(to: ncxURL, atomically: true, encoding: .utf8)
    }
    
    private func generateNCXNavPoints(pageCount: Int) -> String {
        return (1...pageCount).map { pageNumber in
            """
                    <navPoint id="navpoint-\(pageNumber)" playOrder="\(pageNumber)">
                        <navLabel>
                            <text>Page \(pageNumber)</text>
                        </navLabel>
                        <content src="text/page\(pageNumber).xhtml"/>
                    </navPoint>
            """
        }.joined(separator: "\n")
    }
    
    // MARK: - EPUB Packaging
    
    private func packageEPUB(outputName: String) throws -> URL {
        let outputURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConvertedPDFs")
            .appendingPathComponent("\(outputName).epub")
        
        // Ensure output directory exists
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        // Create ZIP archive (EPUB is basically a ZIP file)
        try FileManager.default.zipItem(at: tempDirectory, to: outputURL, shouldKeepParent: false)
        
        return outputURL
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}
