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
        var settings: ConversionSettings? = nil
        
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
        
        // 1. Prepare Batches for Splitting
        var batches: [[(name: String, data: Data)]] = []
        var currentBatch: [(name: String, data: Data)] = []
        var currentBatchSize: Int64 = 0
        let limit = options.settings?.splitMode.limit ?? FileSizeSplitMode.none.limit
        var firstBatchCoverData: Data? = nil
        
        // Extract pages as images
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
                guard let rawCGImage = context.makeImage() else {
                     throw ConversionError.pageRenderFailed(pageIndex + 1)
                }
                
                var cgImageToSave = rawCGImage
                
                if let settings = options.settings, let processed = ImageProcessor.process(image: UIImage(cgImage: rawCGImage), settings: settings), let processedCG = processed.cgImage {
                    cgImageToSave = processedCG
                }
                
                let finalImage = UIImage(cgImage: cgImageToSave)
                let quality = options.settings?.compressionQuality.value ?? 0.8
                let finalData = finalImage.jpegData(compressionQuality: quality) ?? Data()
                
                let imageName = String(format: "page_%04d.jpg", pageIndex + 1)
                
                // Track for auto-splitting
                let itemSize = Int64(finalData.count)
                let overheadBuffer: Int64 = 500 * 1024
                
                if limit != Int64.max && (currentBatchSize + itemSize + overheadBuffer) > limit && !currentBatch.isEmpty {
                    batches.append(currentBatch)
                    currentBatch = []
                    currentBatchSize = 0
                }
                
                if pageIndex == 0 {
                    firstBatchCoverData = finalData
                }
                
                currentBatch.append((name: imageName, data: finalData))
                currentBatchSize += itemSize
            }
        }
        
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        
        var generatedFiles: [URL] = []
        
        // 2. Build EPUBs for each Batch
        for (batchIndex, batch) in batches.enumerated() {
            let partSuffix = batches.count > 1 ? " (pt \(batchIndex + 1))" : ""
            let baseName = title + partSuffix
            
            let batchDir = tempDir.appendingPathComponent("EPUB_Part_\(batchIndex)")
            let oebpsDir = batchDir.appendingPathComponent("OEBPS")
            let metaInfDir = batchDir.appendingPathComponent("META-INF")
            let imagesDir = oebpsDir.appendingPathComponent("images")
            
            try? FileManager.default.removeItem(at: batchDir)
            try FileManager.default.createDirectory(at: oebpsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            
            // Write mimetype
            try "application/epub+zip".write(to: batchDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
            
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
            
            var imageFiles: [String] = []
            
            // Write chunk images
            for item in batch {
                let imageURL = imagesDir.appendingPathComponent(item.name)
                try item.data.write(to: imageURL)
                imageFiles.append(item.name)
            }
            
            // coverHtmlRef removed
            var coverManifestItem = ""
            var coverSpineItem = ""
            
            // ✅ Dynamic Cover Generation for Split Volumes
            if let coverData = firstBatchCoverData, batches.count > 1 {
                print("🎨 PDF dynamically generating Cover Badge for Part \(batchIndex + 1) of \(batches.count)")
                
                let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: batches.count)
                let coverFilename = "badged_cover.jpg"
                try? badgedCoverData.write(to: imagesDir.appendingPathComponent(coverFilename))
                
                coverManifestItem = "<item id=\"cover-image\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>\n<item id=\"cover-page\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
                coverSpineItem = "<itemref idref=\"cover-page\"/>\n"
                // coverHtmlRef = "cover.xhtml" removed
                
                // Write cover.xhtml
                let coverXHTML = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>Cover</title>
                <meta name="viewport" content="width=\(Int(options.maxImageWidth)), height=\(Int(options.maxImageHeight))"/>
                <style type="text/css">
                body { margin: 0; padding: 0; background-color: #000000; }
                .page { position: absolute; width: 100%; height: 100%; margin: 0; padding: 0; }
                img.page-image { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
                </style></head>
                <body><div class="page"><img src="images/\(coverFilename)" class="page-image" alt="Cover"/></div></body>
                </html>
                """
                try? coverXHTML.write(to: oebpsDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
            }
        
        progressHandler?(ConversionProgress(
            currentPage: pageCount,
            totalPages: pageCount,
            phase: .packaging
        ))
        
        let pageLimit = 1 // ✅ REQUIRED: 1 image per file for Fixed-Layout EPUBs
        var xhtmlFiles: [String] = []
        
        // Group images into chunks to prevent single massive HTML files while still allowing dynamic spreads
        let chunks = stride(from: 0, to: imageFiles.count, by: pageLimit).map {
            Array(imageFiles[$0..<min($0 + pageLimit, imageFiles.count)])
        }
        
        for (chunkIndex, chunkImages) in chunks.enumerated() {
            let chunkFileName = String(format: "chunk_%04d.xhtml", chunkIndex + 1)
            
            let chunkXHTML = generateChunkXHTML(
                chunkIndex: chunkIndex + 1,
                images: chunkImages,
                title: title,
                startIndex: (chunkIndex * pageLimit) + 1,
                width: Int(options.maxImageWidth),
                height: Int(options.maxImageHeight)
            )
            try chunkXHTML.write(to: oebpsDir.appendingPathComponent(chunkFileName), atomically: true, encoding: String.Encoding.utf8)
            xhtmlFiles.append(chunkFileName)
        }
        
            // Generate content.opf
            let contentOPF = generateContentOPF(
                title: baseName,
                author: author,
                bookID: bookID,
                imageFiles: imageFiles,
                xhtmlFiles: xhtmlFiles,
                width: Int(options.maxImageWidth),
                height: Int(options.maxImageHeight),
                coverManifest: coverManifestItem,
                coverSpine: coverSpineItem
            )
            try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // Generate toc.ncx
        let tocNCX = generateTocNCX(
            title: title,
            bookID: bookID,
            xhtmlFiles: xhtmlFiles
        )
        try tocNCX.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // Generate nav.xhtml (EPUB3)
        let navXHTML = generateNavXHTML(title: title, xhtmlFiles: xhtmlFiles)
        try navXHTML.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // Generate CSS
        let css = generateCSS()
        try css.write(to: oebpsDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
            // Create EPUB (ZIP) file
            let batchOutputURL = outputURL.deletingPathExtension().appendingPathExtension("pt\(batchIndex+1).epub")
            try createEPUB(from: batchDir, to: batchOutputURL)
            generatedFiles.append(batchOutputURL)
        }
        
        progressHandler?(ConversionProgress(
            currentPage: pageCount,
            totalPages: pageCount,
            phase: .complete
        ))
        
        return (generatedFiles.first ?? outputURL, pageCount)
    }
    
    // MARK: - Private Methods
    
    private func generateContentOPF(title: String, author: String, bookID: String, imageFiles: [String], xhtmlFiles: [String], width: Int, height: Int, coverManifest: String = "", coverSpine: String = "") -> String {
        var manifestItems = coverManifest
        
        // Add XHTML HTML files
        for (index, xhtmlFile) in xhtmlFiles.enumerated() {
            manifestItems += "<item id=\"chunk\(index + 1)\" href=\"\(xhtmlFile)\" media-type=\"application/xhtml+xml\"/>\n        "
        }
        
        // Add Images
        for (index, imageFile) in imageFiles.enumerated() {
            manifestItems += "<item id=\"img\(index + 1)\" href=\"images/\(imageFile)\" media-type=\"image/jpeg\"/>\n        "
        }
        
        // Add standard files
        manifestItems += """
<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>
        <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>
        <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>
"""
        
        var spineItems = coverSpine
        for (index, _) in xhtmlFiles.enumerated() {
            spineItems += "<itemref idref=\"chunk\(index + 1)\"/>\n        "
        }
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">\(bookID)</dc:identifier>
                <dc:title>\(escapeXML(title))</dc:title>
                <dc:creator>\(escapeXML(author))</dc:creator>
                <dc:language>en</dc:language>
                <dc:date>\(ISO8601DateFormatter().string(from: Date()))</dc:date>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>

                <meta name="fixed-layout" content="true"/>
                <meta name="original-resolution" content="\(width)x\(height)"/>
                <meta name="book-type" content="comic"/>
                <meta name="cdetype" content="pdoc"/>
                <meta name="cover" content="img1"/>
                <meta name="zero-gutter" content="true"/>
                <meta name="zero-margin" content="true"/>
                <meta name="ke-border-color" content="#000000"/>
                <meta name="ke-border-width" content="0"/>
                
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
                <meta name="orientation-lock" content="none"/>
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
    
    private func generateTocNCX(title: String, bookID: String, xhtmlFiles: [String]) -> String {
        // For a single content.xhtml, we'll just have one navPoint
        let navPoints = xhtmlFiles.enumerated().map { index, xhtmlFile in
            """
                <navPoint id="navpoint\(index + 1)" playOrder="\(index + 1)">
                    <navLabel><text>Start</text></navLabel>
                    <content src="\(xhtmlFile)"/>
                </navPoint>
            """
        }.joined(separator: "\n        ")
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="\(bookID)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
            </head>
            <docTitle><text>\(escapeXML(title))</text></docTitle>
            <navMap>
                \(navPoints)
            </navMap>
        </ncx>
        """
    }
    
    private func generateNavXHTML(title: String, xhtmlFiles: [String]) -> String {
        // For a single content.xhtml, we'll just have one nav item
        let navItems = xhtmlFiles.enumerated().map { index, xhtmlFile in
            "<li><a href=\"\(xhtmlFile)\">Start</a></li>"
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
    
    private func generateChunkXHTML(chunkIndex: Int, images: [String], title: String, startIndex: Int, width: Int, height: Int) -> String {
        let imageElements = images.enumerated().map { i, imageName in
            """
                  <img src="images/\(imageName)" class="page-image" alt="Page \(startIndex + i)"/>
            """
        }.joined(separator: "\n")
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
            <meta charset="UTF-8"/>
            <meta name="viewport" content="width=\(width), height=\(height)"/>
            <title>\(escapeXML(title))</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
            <div class="page">
        \(imageElements)
            </div>
        </body>
        </html>
        """
    }
    
    private func generateCSS() -> String {
        return """
        @page {
            margin: 0;
            padding: 0;
        }
        body {
            margin: 0;
            padding: 0;
            background-color: #000000;
        }
        .page { 
            position: absolute;
            width: 100%;
            height: 100%;
            margin: 0; 
            padding: 0; 
        }
        .page-image {
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
        }
        """
    }
    
    private func createEPUB(from tempDir: URL, to outputURL: URL) throws {
         if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
            throw NSError(domain: "Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create EPUB archive"])
        }
        
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
