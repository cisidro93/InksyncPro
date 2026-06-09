import Foundation
import PDFKit
import UIKit
import ZIPFoundation
import ImageIO
import MobileCoreServices

/// Service to convert PDF files to EPUB format
/// Extracts PDF pages as images and packages them into a valid EPUB structure
final class PDFToEPUBConverter: Sendable {
    
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
    
    struct ConversionOptions: Sendable {
        var imageQuality: CGFloat = 0.85
        var maxImageWidth: CGFloat = 1600
        var maxImageHeight: CGFloat = 2400
        var title: String?
        var author: String?
        var settings: ConversionSettings? = nil
        var mangaMode: Bool = false
        
        static let `default` = ConversionOptions()
        static let highQuality = ConversionOptions(imageQuality: 0.95, maxImageWidth: 2048, maxImageHeight: 3072)
        static let compressed = ConversionOptions(imageQuality: 0.7, maxImageWidth: 1200, maxImageHeight: 1800)
    }
    
    struct ConversionProgress: Sendable {
        let currentPage: Int
        let totalPages: Int
        let phase: Phase
        
        enum Phase: String, Sendable {
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
        progressHandler: (@Sendable (ConversionProgress) -> Void)? = nil
    ) async throws -> (URL, Int) {
        
        // Load PDF
        let pdfDocument = try ConcurrencyLocks.pdfLock.withLock {
            guard let doc = PDFDocument(url: pdfURL) else {
                throw ConversionError.pdfLoadFailed
            }
            return doc
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
        
        // 1. Prepare Batches for Streaming Disk IO (🚨 COMPETITOR FIX)
        var batchDirectories: [URL] = []
        var batchImageManifests: [[String]] = []
        
        var currentBatchIndex = 0
        var currentBatchImages: [String] = []
        var currentBatchSize: Int64 = 0
        
        let limit = options.settings?.splitMode.limit ?? FileSizeSplitMode.none.limit
        var firstBatchCoverData: Data? = nil
        
        // Helper to setup a batch directory immediately upon creation
        func createBatchDir(index: Int) throws -> URL {
            let batchDir = tempDir.appendingPathComponent("EPUB_Part_\(index)")
            let oebpsDir = batchDir.appendingPathComponent("OEBPS")
            let imagesDir = oebpsDir.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            return batchDir
        }
        
        var currentBatchDir = try createBatchDir(index: 0)
        batchDirectories.append(currentBatchDir)
        
        // Extract pages as images
        for pageIndex in 0..<pageCount {
            progressHandler?(ConversionProgress(
                currentPage: pageIndex + 1,
                totalPages: pageCount,
                phase: .extracting
            ))
            
            try autoreleasepool {
                let rawCGImage = try ConcurrencyLocks.pdfLock.withLock { () throws -> CGImage? in
                    guard let page = pdfDocument.page(at: pageIndex) else {
                        throw ConversionError.pageRenderFailed(pageIndex + 1)
                    }
                    
                    // Render page to image
                    let pageRect = page.bounds(for: .mediaBox)
                    
                    // Safety check for invalid dimensions
                    guard pageRect.width > 0, pageRect.height > 0 else {
                        print("Skipping page \(pageIndex + 1) due to invalid dimensions: \(pageRect)")
                        return nil // Skip this page instead of crashing
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
                    guard scaledSize.width > 1, scaledSize.height > 1 else { return nil }
                    
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
                    guard let raw = context.makeImage() else {
                         throw ConversionError.pageRenderFailed(pageIndex + 1)
                    }
                    return raw
                }
                
                guard let cgImageToSave = rawCGImage else { return }
                
                var finalCGImage = cgImageToSave
                if let settings = options.settings, let processed = ImageProcessor.process(image: UIImage(cgImage: cgImageToSave), settings: settings), let processedCG = processed.cgImage {
                    finalCGImage = processedCG
                }
                
                let finalImage = UIImage(cgImage: finalCGImage)
                let quality = options.settings?.compressionQuality.value ?? 0.8
                let finalData = finalImage.jpegData(compressionQuality: quality) ?? Data()
                
                let imageName = String(format: "page_%04d.jpg", pageIndex + 1)
                
                // Track for auto-splitting
                let itemSize = Int64(finalData.count)
                let overheadBuffer: Int64 = 500 * 1024
                
                // Splitting boundary check
                if limit != Int64.max && (currentBatchSize + itemSize + overheadBuffer) > limit && !currentBatchImages.isEmpty {
                    // Close out the old batch
                    batchImageManifests.append(currentBatchImages)
                    
                    // Startup the new batch
                    currentBatchIndex += 1
                    currentBatchDir = try createBatchDir(index: currentBatchIndex)
                    batchDirectories.append(currentBatchDir)
                    
                    currentBatchImages = []
                    currentBatchSize = 0
                }
                
                // 🚨 COMPETITOR FIX: Instant Direct IO Writing (Zero Byte Retention)
                let imageWriteURL = currentBatchDir.appendingPathComponent("OEBPS/images").appendingPathComponent(imageName)
                try? finalData.write(to: imageWriteURL)
                
                if pageIndex == 0 {
                    firstBatchCoverData = finalData
                }
                
                currentBatchImages.append(imageName)
                currentBatchSize += itemSize
            }
        }
        
        if !currentBatchImages.isEmpty {
            batchImageManifests.append(currentBatchImages)
        }
        
        var generatedFiles: [URL] = []
        
        // 2. Build EPUBs for each Batch Directory
        for (batchIndex, batchDir) in batchDirectories.enumerated() {
            let partSuffix = batchDirectories.count > 1 ? " (pt \(batchIndex + 1))" : ""
            let baseName = title + partSuffix
            let imageFiles = batchImageManifests[batchIndex]
            
            let oebpsDir = batchDir.appendingPathComponent("OEBPS")
            let metaInfDir = batchDir.appendingPathComponent("META-INF")
            let imagesDir = oebpsDir.appendingPathComponent("images")
            
            try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
            
            // Write mimetype
            try "application/epub+zip".write(to: batchDir.appendingPathComponent("mimetype"), atomically: true, encoding: String.Encoding.utf8)
            
            // Write container.xml
            let containerXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles>
            </container>
            """
            try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: String.Encoding.utf8)
            
            // coverHtmlRef removed
            var coverManifestItem = ""
            var coverSpineItem = ""
            
            // ✅ Dynamic Cover Generation for Split Volumes
            if let coverData = firstBatchCoverData, batchDirectories.count > 1 {
                print("🎨 PDF dynamically generating Cover Badge for Part \(batchIndex + 1) of \(batchDirectories.count)")
                
                let badgedCoverData = CoverGenerator.generateCover(from: coverData, partNumber: batchIndex + 1, totalParts: batchDirectories.count)
                let coverFilename = "badged_cover.jpg"
                try? badgedCoverData.write(to: imagesDir.appendingPathComponent(coverFilename))
                coverManifestItem = "<item id=\"cover-image\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\"/>\n<item id=\"cover-page\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
                coverSpineItem = "<itemref idref=\"cover-page\"/>\n"
                // Write cover.xhtml
                let lang = options.mangaMode ? "ja" : "en"
                let coverXHTML = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
                <head>
                    <title>Cover</title>
                    <meta name="viewport" content="width=1000, height=1500"/>
                </head>
                <body style="margin: 0; padding: 0; background-color: #000000;">
                    <div style="position: absolute; top: 0; left: 0; width: 100%; height: 100%; margin: 0; padding: 0;">
                        <img style="position: absolute; top: 0; left: 0; width: 100%; height: 100%;" src="images/\(coverFilename)" alt="Cover"/>
                    </div>
                </body>
                </html>
                """
                try? coverXHTML.write(to: oebpsDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: String.Encoding.utf8)
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
                isManga: options.mangaMode
            )
            try chunkXHTML.write(to: oebpsDir.appendingPathComponent(chunkFileName), atomically: true, encoding: String.Encoding.utf8)
            xhtmlFiles.append(chunkFileName)
        }
        
            let coverMetaContent = (firstBatchCoverData != nil && batchDirectories.count > 1) ? "cover-image" : "img1"

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
                coverSpine: coverSpineItem,
                coverMetaID: coverMetaContent,
                mangaMode: options.mangaMode
            )
            try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: String.Encoding.utf8)
        
        // 🚨 CRITICAL FIX: Amazon 5.19.3 expects toc.ncx, or else throws E013 and strips Fixed-Layout
        let ncxContent = generateNCX(title: title, bookID: bookID, pageCount: xhtmlFiles.count)
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: String.Encoding.utf8)
        
        // Generate nav.xhtml (EPUB3)
        let navXHTML = generateNavXHTML(title: title, xhtmlFiles: xhtmlFiles, isManga: options.mangaMode)
        try navXHTML.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: String.Encoding.utf8)
        
        // 🚨 CRITICAL FIX: Generate global style.css overriding Amazon's @page Region padding
        let cssContent = """
        @page { margin: 0; padding: 0; }
        body, html { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
        div { margin: 0; padding: 0; position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
        img { margin: 0; padding: 0; position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
        """
        try cssContent.write(to: oebpsDir.appendingPathComponent("style.css"), atomically: true, encoding: String.Encoding.utf8)
        
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
    
    private func generateContentOPF(title: String, author: String, bookID: String, imageFiles: [String], xhtmlFiles: [String], width: Int, height: Int, coverManifest: String = "", coverSpine: String = "", coverMetaID: String = "img1", mangaMode: Bool = false) -> String {
        var manifestItems = coverManifest
        
        // Add XHTML HTML files
        for (index, xhtmlFile) in xhtmlFiles.enumerated() {
            manifestItems += "<item id=\"chunk\(index + 1)\" href=\"\(xhtmlFile)\" media-type=\"application/xhtml+xml\"/>\n        "
        }
        
        // Add Images
        for (index, imageFile) in imageFiles.enumerated() {
            let propertiesAttr = (index == 0 && coverManifest.isEmpty) ? " properties=\"cover-image\"" : ""
            manifestItems += "<item id=\"img\(index + 1)\" href=\"images/\(imageFile)\" media-type=\"image/jpeg\"\(propertiesAttr)/>\n        "
        }
        
        // Add standard files
        manifestItems += """
<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>
"""
        
        var spineItems = coverSpine
        for (index, _) in xhtmlFiles.enumerated() {
            spineItems += "<itemref idref=\"chunk\(index + 1)\"/>\n        "
        }
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookId">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(escapeXML(title))</dc:title>
                <dc:creator>\(escapeXML(author))</dc:creator>
                <dc:language>\(mangaMode ? "ja" : "en")</dc:language>
                <dc:identifier id="BookId">urn:uuid:\(bookID)</dc:identifier>
                
                <!-- Strict Fixed-Layout Flags -->
                <meta name="fixed-layout" content="true"/>
                <meta name="original-resolution" content="1000x1500"/>
                <meta name="orientation-lock" content="none"/>
                <meta name="book-type" content="comic"/>
                <!-- Suppresses "Learning reading speed" — signals image-based content to Kindle firmware -->
                <meta name="amzn:kindle:book-type" content="image-based"/>
                <meta name="zero-gutter" content="true"/>
                <meta name="zero-margin" content="true"/>
                <meta name="ke-border-color" content="#000000"/>
                <meta name="ke-border-width" content="0"/>
                <meta name="cover" content="\(coverMetaID)"/>
                
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:spread">auto</meta>
                <meta property="rendition:orientation">auto</meta>
            </metadata>
            <manifest>
                \(manifestItems)
                <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>
                <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>
            </manifest>
            <spine toc=\"ncx\" page-progression-direction="\(mangaMode ? "rtl" : "ltr")">
                \(spineItems)
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="chunk_0001.xhtml"/>
                <reference type="text" title="Text" href="chunk_0001.xhtml"/>
            </guide>
        </package>
        """
    }
    
    // AWS Server-Side E013 NCX Compatibility Bridge
    private func generateNCX(title: String, bookID: String, pageCount: Int) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="urn:uuid:\(bookID)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pageCount)"/>
                <meta name="dtb:maxPageNumber" content="\(pageCount)"/>
            </head>
            <docTitle><text>\(escapeXML(title))</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="chunk_0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
    }
    
    private func generateNavXHTML(title: String, xhtmlFiles: [String], isManga: Bool) -> String {
        // For a single content.xhtml, we'll just have one nav item
        let navItems = xhtmlFiles.enumerated().map { index, xhtmlFile in
            "<li><a href=\"\(xhtmlFile)\">Start</a></li>"
        }.joined(separator: "\n                ")
        
        let firstFile = xhtmlFiles.first ?? "chunk_0001.xhtml"
        
        let lang = isManga ? "ja" : "en"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
        <head>
            <meta charset="utf-8" />
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
            <nav epub:type="landmarks">
                <h1>Landmarks</h1>
                <ol>
                    <li><a epub:type="cover" href="\(firstFile)">Cover</a></li>
                    <li><a epub:type="bodymatter" href="\(firstFile)">Start</a></li>
                </ol>
            </nav>
        </body>
        </html>
        """
    }
    
    private func generateChunkXHTML(chunkIndex: Int, images: [String], title: String, startIndex: Int, isManga: Bool) -> String {
        let imageElements = images.enumerated().map { i, imageName in
            """
            <img style="position: absolute; top: 0; left: 0; width: 100%; height: 100%;" src="images/\(imageName)" alt="Page \(startIndex + i)"/>
            """
        }.joined(separator: "\n")
        
        let lang = isManga ? "ja" : "en"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
        <head>
            <title>\(escapeXML(title))</title>
            <meta name="viewport" content="width=1000, height=1500"/>
            <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
            <div>
                \(imageElements)
            </div>
        </body>
        </html>
        """
    }
    
    // Inline CSS replaced external generation method
    
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
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: resourceKeys) else {
            throw ConversionError.fileWriteFailed
        }
        
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
