import Foundation
import UIKit
import ZIPFoundation

// MARK: - Data Models

struct ComicPage {
    let imageURL: URL
    let width: Int
    let height: Int
}

// MARK: - CBZToEPUBConverter (Complete Rewrite)

class CBZToEPUBConverter {
    
    // MARK: - Public Interface
    
    func convertCBZToEPUB(_ cbzURL: URL, compressionQuality: Double) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.performConversion(cbzURL: cbzURL, compressionQuality: compressionQuality)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Conversion Pipeline
    
    private func performConversion(cbzURL: URL, compressionQuality: Double) throws -> URL {
        // 1. Setup temporary workspace
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        print("📦 Extracting CBZ...")
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.unzipItem(at: cbzURL, to: extractDir)
        
        // 2. Scan and load comic pages
        print("📸 Scanning images...")
        let pages = try scanComicPages(in: extractDir)
        print("✅ Found \(pages.count) pages")
        
        guard !pages.isEmpty else {
            throw NSError(domain: "CBZConverter", code: 404, userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ"])
        }
        
        // 3. Build EPUB structure
        print("📚 Building EPUB...")
        let title = cbzURL.deletingPathExtension().lastPathComponent
        let epubURL = try buildEPUB(
            pages: pages,
            title: title,
            outputDir: tempDir,
            compressionQuality: compressionQuality
        )
        
        // 4. Move to persistent location
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.copyItem(at: epubURL, to: finalURL)
        
        print("✅ EPUB created successfully")
        return finalURL
    }
    
    // MARK: - Image Scanning
    
    private func scanComicPages(in directory: URL) throws -> [ComicPage] {
        var pages: [ComicPage] = []
        let supportedExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return pages
        }
        
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            
            // Skip metadata files
            if fileURL.lastPathComponent.hasPrefix(".") ||
               fileURL.lastPathComponent.hasPrefix("__") ||
               fileURL.path.contains("__MACOSX") {
                continue
            }
            
            // Only process supported image formats
            guard supportedExtensions.contains(ext) else { continue }
            
            // Load image and get ACTUAL pixel dimensions
            guard let image = UIImage(contentsOfFile: fileURL.path),
                  let cgImage = image.cgImage else { continue }
            
            let width = cgImage.width
            let height = cgImage.height
            
            pages.append(ComicPage(imageURL: fileURL, width: width, height: height))
        }
        
        // Sort alphanumerically
        pages.sort { $0.imageURL.lastPathComponent.localizedStandardCompare($1.imageURL.lastPathComponent) == .orderedAscending }
        
        return pages
    }
    
    // MARK: - EPUB Generation
    
    private func buildEPUB(pages: [ComicPage], title: String, outputDir: URL, compressionQuality: Double) throws -> URL {
        
        // Create EPUB directory structure
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        // 1. Create mimetype (MUST be first, uncompressed)
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        
        // 2. Create container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // 3. Process images and generate XHTML
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, page) in pages.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let imageName = "page\(pageNum).jpg"
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // Load and process image
            guard let sourceImage = UIImage(contentsOfFile: page.imageURL.path),
                  let cgImage = sourceImage.cgImage else {
                print("⚠️ Failed to load: \(page.imageURL.lastPathComponent)")
                continue
            }
            
            // Get actual pixel dimensions
            let sourceWidth = CGFloat(cgImage.width)
            let sourceHeight = CGFloat(cgImage.height)
            
            // Calculate target size (max 2400px as per blueprint)
            let maxDimension: CGFloat = 2400
            var targetWidth = sourceWidth
            var targetHeight = sourceHeight
            
            if sourceWidth > maxDimension || sourceHeight > maxDimension {
                let scale = min(maxDimension / sourceWidth, maxDimension / sourceHeight, 1.0)
                targetWidth = (sourceWidth * scale).rounded()
                targetHeight = (sourceHeight * scale).rounded()
            }
            
            let targetSize = CGSize(width: targetWidth, height: targetHeight)
            
            // Create bitmap context (NO TILING - single draw operation)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            
            guard let context = CGContext(
                data: nil,
                width: Int(targetSize.width),
                height: Int(targetSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                print("⚠️ Failed to create context for: \(page.imageURL.lastPathComponent)")
                continue
            }
            
            // Draw image with high quality
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))
            
            // Extract rendered image
            guard let renderedCGImage = context.makeImage() else {
                print("⚠️ Failed to render: \(page.imageURL.lastPathComponent)")
                continue
            }
            
            // Convert to UIImage and save as JPEG
            let finalImage = UIImage(cgImage: renderedCGImage)
            guard let jpegData = finalImage.jpegData(compressionQuality: compressionQuality) else {
                print("⚠️ Failed to encode JPEG: \(imageName)")
                continue
            }
            
            try jpegData.write(to: imageDestURL)
            print("✅ Saved: \(imageName) (\(Int(targetSize.width))x\(Int(targetSize.height))) - \(jpegData.count / 1024)KB")
            
            // Add to manifest
            imageManifest += "    <item id=\"img_\(pageNum)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            // Generate XHTML with correct viewport
            let xhtmlContent = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <link href="../styles.css" type="text/css" rel="stylesheet"/>
                <meta name="viewport" content="width=\(Int(targetSize.width)), height=\(Int(targetSize.height))" />
            </head>
            <body>
                <div class="page">
                    <img src="../images/\(imageName)" alt="Page \(index + 1)" />
                </div>
            </body>
            </html>
            """
            
            let xhtmlName = "page\(pageNum).xhtml"
            try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
            
            xhtmlManifest += "    <item id=\"page_\(pageNum)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "    <itemref idref=\"page_\(pageNum)\"/>\n"
        }
        
        // 4. Create content.opf (with Fixed-Layout metadata)
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="stylesheet" href="styles.css" media-type="text/css"/>
        \(imageManifest)\(xhtmlManifest)    </manifest>
            <spine toc="ncx">
        \(spineItems)    </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 5. Create toc.ncx
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="urn:uuid:\(UUID().uuidString)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pages.count)"/>
                <meta name="dtb:maxPageNumber" content="\(pages.count)"/>
            </head>
            <docTitle><text>\(title)</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page0001.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 6. Create styles.css
        let cssContent = """
        body {
            margin: 0;
            padding: 0;
            background-color: black;
        }
        
        .page {
            width: 100%;
            height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        
        img {
            max-width: 100%;
            max-height: 100%;
            display: block;
        }
        """
        try cssContent.write(to: oebpsDir.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        
        // 7. Package as EPUB (ZIP with specific ordering)
        let finalEPUB = outputDir.appendingPathComponent("\(title).epub")
        let archive = try Archive(url: finalEPUB, accessMode: .create)
        
        // Add mimetype FIRST and UNCOMPRESSED (critical for EPUB spec)
        try archive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: 20,
            compressionMethod: .none
        ) { position, size in
            return try Data(contentsOf: epubDir.appendingPathComponent("mimetype"))
        }
        
        // Add all other files (compressed)
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: epubDir,
            includingPropertiesForKeys: resourceKeys
        ) else {
            throw NSError(domain: "EPUB", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate EPUB directory"])
        }
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = resourceValues.isDirectory ?? false
            let path = fileURL.path.replacingOccurrences(of: epubDir.path + "/", with: "")
            
            // Skip mimetype (already added) and empty paths
            if path == "mimetype" || path.isEmpty { continue }
            
            // Only add files, not directories
            if !isDirectory {
                let fileSize = UInt32(resourceValues.fileSize ?? 0)
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(fileSize),
                    compressionMethod: .deflate
                ) { position, size in
                    return try Data(contentsOf: fileURL).subdata(in: 0..<Int(size))
                }
            }
        }
        
        return finalEPUB
    }
}
