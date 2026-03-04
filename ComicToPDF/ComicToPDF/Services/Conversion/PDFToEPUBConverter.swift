import Foundation
import PDFKit
import UIKit
import ZIPFoundation
import ImageIO
import MobileCoreServices

/// Service to convert PDF files to EPUB format
/// Extracts PDF pages as images and packages them into a valid EPUB structure
class PDFToEPUBConverter {
    
    enum ConversionError: LocalizedError {
        case pdfLoadFailed
        case noPages
        case pageRenderFailed(Int)
        case epubCreationFailed
        case fileWriteFailed
        
        var errorDescription: String? {
            switch self {
            case .pdfLoadFailed:
                return "Failed to load PDF file"
            case .noPages:
                return "PDF contains no pages"
            case .pageRenderFailed(let page):
                return "Failed to render page \(page)"
            case .epubCreationFailed:
                return "Failed to create EPUB structure"
            case .fileWriteFailed:
                return "Failed to write EPUB file"
            }
        }
    }
    
    struct ConversionOptions {
        var imageQuality: CGFloat = 0.85
        var maxImageWidth: CGFloat = 1600
        var maxImageHeight: CGFloat = 2400
        var title: String?
        var author: String?
        
        static let `default` = ConversionOptions()
        static let highQuality = ConversionOptions(imageQuality: 0.95, maxImageWidth: 2048, maxImageHeight: 3072)
        static let compressed = ConversionOptions(imageQuality: 0.7, maxImageWidth: 1200, maxImageHeight: 1800)
    }
    
    struct ConversionProgress {
        let currentPage: Int
        let totalPages: Int
        let phase: Phase
        
        enum Phase: String {
            case extracting = "Extracting pages"
            case packaging = "Creating EPUB"
            case complete = "Complete"
        }
        
        var percentage: Double {
            guard totalPages > 0 else { return 0 }
            return Double(currentPage) / Double(totalPages)
        }
    }
    
    // MARK: - Public Methods
    
    /// Convert a PDF file to EPUB format
    /// - Parameters:
    ///   - pdfURL: URL of the source PDF file
    ///   - outputURL: URL for the output EPUB file
    ///   - options: Conversion options
    ///   - progressHandler: Optional callback for progress updates
    /// - Returns: URL of the created EPUB file
    func convert(
        pdfURL: URL,
        to outputURL: URL,
        options: ConversionOptions = .default,
        progressHandler: ((ConversionProgress) -> Void)? = nil
    ) async throws -> (URL, Int) {
        
        // Load PDF
        guard let pdfDocument = PDFDocument(url: pdfURL) else {
            throw ConversionError.pdfLoadFailed
        }
        
        let pageCount = pdfDocument.pageCount
        guard pageCount > 0 else {
            throw ConversionError.noPages
        }
        
        // Create temp directory for EPUB contents
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Extract title from filename or options
        let title = options.title ?? pdfURL.deletingPathExtension().lastPathComponent
        let author = options.author ?? "Inksync Pro"
        let bookID = UUID().uuidString
        
        // Create EPUB directory structure
        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        let metaInfDir = tempDir.appendingPathComponent("META-INF")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        
        try FileManager.default.createDirectory(at: oebpsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        
        // Write mimetype (must be first, uncompressed)
        let mimetypeURL = tempDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypeURL, atomically: true, encoding: .utf8)
        
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
        
        // Extract pages as images
        var imageFiles: [String] = []
        
        for pageIndex in 0..<pageCount {
            progressHandler?(ConversionProgress(
                currentPage: pageIndex + 1,
                totalPages: pageCount,
                phase: .extracting
            ))
            
            try autoreleasepool {
                guard let page = pdfDocument.page(at: pageIndex) else {
                    throw ConversionError.pageRenderFailed(pageIndex + 1)
                }
                
                // Render page to image
                let pageRect = page.bounds(for: .mediaBox)
                
                // Safety check for invalid dimensions
                guard pageRect.width > 0, pageRect.height > 0 else {
                    print("Skipping page \(pageIndex + 1) due to invalid dimensions: \(pageRect)")
                    return // Skip this page instead of crashing
                }
                
                let scale = min(
                    options.maxImageWidth / pageRect.width,
                    options.maxImageHeight / pageRect.height,
                    2.0 // Max 2x scale
                )
                
                let scaledSize = CGSize(
                    width: checkFinite(pageRect.width * scale).rounded(),
                    height: checkFinite(pageRect.height * scale).rounded()
                )
                
                // Double check scaled size logic to prevent invalid image context
                guard scaledSize.width > 1, scaledSize.height > 1 else { return }
                
                // FIX: Use Low-Level CGBitmapContext to avoid UIGraphicsImageRenderer stripping artifacts
                let width = Int(scaledSize.width)
                let height = Int(scaledSize.height)
                let bitsPerComponent = 8
                let bytesPerRow = 0 // Auto
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue // Opaque RGB
                
                guard let context = CGContext(data: nil,
                                            width: width,
                                            height: height,
                                            bitsPerComponent: bitsPerComponent,
                                            bytesPerRow: bytesPerRow,
                                            space: colorSpace,
                                            bitmapInfo: bitmapInfo) else {
                    throw ConversionError.pageRenderFailed(pageIndex + 1)
                }
                
                // Draw White Background
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: scaledSize))
                
                // Draw PDF Page
                // Flip coords for CoreGraphics
                context.translateBy(x: 0, y: scaledSize.height)
                context.scaleBy(x: scale, y: -scale)
                
                page.draw(with: .mediaBox, to: context)
                
                // Create Image from Context
                guard let cgImage = context.makeImage() else {
                     throw ConversionError.pageRenderFailed(pageIndex + 1)
                }
                
                // Save as JPEG using ImageIO (Direct Transcode)
                let imageName = String(format: "page_%04d.jpg", pageIndex + 1)
                let imageURL = imagesDir.appendingPathComponent(imageName)
                
                guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
                     throw ConversionError.fileWriteFailed
                }
                
                let imageOptions: [String: Any] = [
                    kCGImageDestinationLossyCompressionQuality as String: options.imageQuality
                ]
                
                CGImageDestinationAddImage(destination, cgImage, imageOptions as CFDictionary)
                if !CGImageDestinationFinalize(destination) {
                     throw ConversionError.fileWriteFailed
                }
                
                imageFiles.append(imageName)
            }
        }
        
        progressHandler?(ConversionProgress(
            currentPage: pageCount,
            totalPages: pageCount,
            phase: .packaging
        ))
        
        // Generate content.opf
        let contentOPF = generateContentOPF(
            title: title,
            author: author,
            bookID: bookID,
            imageFiles: imageFiles
        )
        try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // Generate toc.ncx
        let tocNCX = generateTocNCX(
            title: title,
            bookID: bookID,
            pageCount: pageCount
        )
        try tocNCX.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // Generate nav.xhtml (EPUB3)
        let navXHTML = generateNavXHTML(title: title, pageCount: pageCount)
        try navXHTML.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // Generate page XHTML files
        for (index, imageName) in imageFiles.enumerated() {
            let pageXHTML = generatePageXHTML(
                pageNumber: index + 1,
                imageName: imageName,
                title: title
            )
            let pageFileName = String(format: "page_%04d.xhtml", index + 1)
            try pageXHTML.write(to: oebpsDir.appendingPathComponent(pageFileName), atomically: true, encoding: .utf8)
        }
        
        // Generate CSS
        let css = generateCSS()
        try css.write(to: oebpsDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
        // Create EPUB (ZIP) file
        try createEPUB(from: tempDir, to: outputURL)
        
        progressHandler?(ConversionProgress(
            currentPage: pageCount,
            totalPages: pageCount,
            phase: .complete
        ))
        
        return (outputURL, pageCount)
    }
    
    // MARK: - Private Methods
    
    private func generateContentOPF(title: String, author: String, bookID: String, imageFiles: [String]) -> String {
        let manifestItems = imageFiles.enumerated().map { index, imageName in
            let pageFileName = String(format: "page_%04d.xhtml", index + 1)
            return """
                <item id="page\(index + 1)" href="\(pageFileName)" media-type="application/xhtml+xml"/>
                <item id="img\(index + 1)" href="images/\(imageName)" media-type="image/jpeg"/>
            """
        }.joined(separator: "\n        ")
        
        let spineItems = imageFiles.enumerated().map { index, _ in
            let isOdd = (index % 2 != 0)
            let spreadProp = isOdd ? "page-spread-left" : "page-spread-right"
            return "<itemref idref=\"page\(index + 1)\" properties=\"\(spreadProp)\"/>"
        }.joined(separator: "\n        ")
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">\(bookID)</dc:identifier>
                <dc:title>\(escapeXML(title))</dc:title>
                <dc:creator>\(escapeXML(author))</dc:creator>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta name="cover" content="img1"/>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="css" href="style.css" media-type="text/css"/>
                \(manifestItems)
            </manifest>
            <spine toc="ncx">
                \(spineItems)
            </spine>
        </package>
        """
    }
    
    private func generateTocNCX(title: String, bookID: String, pageCount: Int) -> String {
        let navPoints = (1...pageCount).map { page in
            """
                <navPoint id="navpoint\(page)" playOrder="\(page)">
                    <navLabel><text>Page \(page)</text></navLabel>
                    <content src="\(String(format: "page_%04d.xhtml", page))"/>
                </navPoint>
            """
        }.joined(separator: "\n        ")
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="\(bookID)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pageCount)"/>
                <meta name="dtb:maxPageNumber" content="\(pageCount)"/>
            </head>
            <docTitle><text>\(escapeXML(title))</text></docTitle>
            <navMap>
                \(navPoints)
            </navMap>
        </ncx>
        """
    }
    
    private func generateNavXHTML(title: String, pageCount: Int) -> String {
        let navItems = (1...pageCount).map { page in
            "<li><a href=\"\(String(format: "page_%04d.xhtml", page))\">Page \(page)</a></li>"
        }.joined(separator: "\n                ")
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
            <title>\(escapeXML(title))</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
            <nav epub:type="toc" id="toc">
                <h1>Table of Contents</h1>
                <ol>
                    \(navItems)
                </ol>
            </nav>
        </body>
        </html>
        """
    }
    
    private func generatePageXHTML(pageNumber: Int, imageName: String, title: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>\(escapeXML(title)) - Page \(pageNumber)</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
            <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
        </head>
        <body>
            <div class="page">
                <img src="images/\(imageName)" alt="Page \(pageNumber)"/>
            </div>
        </body>
        </html>
        """
    }
    
    private func generateCSS() -> String {
        return """
        /* Comic EPUB Styles */
        html, body { 
            width: 100%; 
            height: 100%; 
            margin: 0; 
            padding: 0; 
            background-color: #000000; 
        }
        .page { 
            text-align: center;
            height: 100%; 
            margin: 0; 
            padding: 0; 
        }
        .page img {
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
        }
        """
    }
    
    private func createEPUB(from tempDir: URL, to outputURL: URL) throws {
         if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        let archive = try Archive(url: outputURL, accessMode: .create)
        
        // 1. Mimetype (MUST be first and uncompressed)
        let mimetypeURL = tempDir.appendingPathComponent("mimetype")
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(20), compressionMethod: .none) { position, size in
            return try Data(contentsOf: mimetypeURL).subdata(in: 0..<Int(size))
        }
        
        // 2. Add remaining files
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: resourceKeys)!
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = resourceValues.isDirectory ?? false
            let path = fileURL.path.replacingOccurrences(of: tempDir.path + "/", with: "")
            
            if path == "mimetype" || path.isEmpty { continue }
            
            if !isDirectory {
                let fileSize = UInt32(resourceValues.fileSize ?? 0)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(fileSize), compressionMethod: .deflate) { position, size in
                    return try Data(contentsOf: fileURL).subdata(in: 0..<Int(size))
                }
            } else {
                 try archive.addEntry(with: path + "/", type: .directory, uncompressedSize: Int64(0), compressionMethod: .none) { _, _ in Data() }
            }
        }
    }
    
    private func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Convenience Extension

extension PDFToEPUBConverter {
    
    /// Quick convert with default options
    static func convert(pdf pdfURL: URL, to outputURL: URL) async throws -> (url: URL, pageCount: Int) {
        let converter = PDFToEPUBConverter()
        let (url, pageCount) = try await converter.convert(pdfURL: pdfURL, to: outputURL)
        return (url, pageCount)
    }
    
    /// Convert with progress tracking using Combine
    func convertWithProgress(
        pdfURL: URL,
        to outputURL: URL,
        options: ConversionOptions = .default
    ) -> AsyncThrowingStream<ConversionProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    _ = try await convert(pdfURL: pdfURL, to: outputURL, options: options) { progress in
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // Helper to ensure values are valid numbers
    private func checkFinite(_ value: CGFloat) -> CGFloat {
        return value.isFinite ? value : 0
    }
}
