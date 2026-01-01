import UIKit
import ZIPFoundation

/// Handles EPUB splitting ensuring strict binary copy of images to prevent corruption.
class ComicEPUBProcessor {
    static let shared = ComicEPUBProcessor()
    
    enum SplitError: Error, LocalizedError {
        case invalidSource
        case structuralError(String)
        case splittingFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidSource: return "Invalid source EPUB file"
            case .structuralError(let msg): return "EPUB Structure Error: \(msg)"
            case .splittingFailed(let msg): return "Splitting Failed: \(msg)"
            }
        }
    }
    
    struct PageItem {
        let xhtmlPath: String
        let imagePath: String
        let fullPathInZip: String // e.g. OEBPS/text/page01.xhtml
    }
    
    /// Splits an EPUB into multiple parts if it exceeds the size limit.
    /// STRICT RULE: Images are copied as BINARY FILES. No decoding/re-encoding.
    static func splitEPUB(_ epubURL: URL, maxSizeMB: Int) throws -> [URL] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("EPUBSplit_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 1. Unzip Source
        let sourceDir = tempDir.appendingPathComponent("Source")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: epubURL, to: sourceDir)
        
        // 2. Analyze Content (Find OEBPS, Images, pages)
        // We assume standard structure created by our Converter: OEBPS/images, OEBPS/text
        let oebpsDir = sourceDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        guard fileManager.fileExists(atPath: oebpsDir.path),
              fileManager.fileExists(atPath: imagesDir.path),
              fileManager.fileExists(atPath: textDir.path) else {
            // If structure is different, we abort to allow fallback or throw
            throw SplitError.structuralError("Standard OEBPS/images/text structure not found")
        }
        
        // Find all pages
        var pages: [PageItem] = []
        let enumerator = fileManager.enumerator(at: textDir, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "xhtml" {
                // let filename = fileURL.lastPathComponent
                // Assumption: page0001.xhtml pairs with page0001.jpg/png
                let basename = fileURL.deletingPathExtension().lastPathComponent
                
                // Find corresponding image
                var imageFile: URL?
                for ext in ["jpg", "jpeg", "png", "gif", "webp"] {
                    let imgURL = imagesDir.appendingPathComponent("\(basename).\(ext)")
                    if fileManager.fileExists(atPath: imgURL.path) {
                        imageFile = imgURL
                        break
                    }
                }
                
                if let img = imageFile {
                    pages.append(PageItem(
                        xhtmlPath: fileURL.path,
                        imagePath: img.path,
                        fullPathInZip: "" // Not used in this logic
                    ))
                }
            }
        }
        
        // Sort pages
        pages.sort { $0.xhtmlPath.localizedStandardCompare($1.xhtmlPath) == .orderedAscending }
        
        if pages.isEmpty { return [epubURL] } // Nothing to split
        
        // 3. Split Logic
        var splitURLs: [URL] = []
        let maxBytes = Int64(maxSizeMB * 1024 * 1024)
        var currentPages: [PageItem] = []
        var currentSize: Int64 = 0
        var partIndex = 1
        
        let commonFilesSize: Int64 = 50 * 1024 // Estimate for overhead (container, css, fonts)
        
        for page in pages {
            let xhtmlSize = (try? fileManager.attributesOfItem(atPath: page.xhtmlPath)[.size] as? Int64) ?? 0
            let imageSize = (try? fileManager.attributesOfItem(atPath: page.imagePath)[.size] as? Int64) ?? 0
            let pageSize = xhtmlSize + imageSize
            
            if currentSize + pageSize + commonFilesSize > maxBytes && !currentPages.isEmpty {
                // Flush current part
                let partURL = try createSplitPart(
                    from: sourceDir,
                    pages: currentPages,
                    partIndex: partIndex,
                    originalName: epubURL.deletingPathExtension().lastPathComponent,
                    outputDir: tempDir
                )
                splitURLs.append(partURL)
                
                // Reset
                partIndex += 1
                currentPages = []
                currentSize = 0
            }
            
            currentPages.append(page)
            currentSize += pageSize
        }
        
        // Flush remaining
        if !currentPages.isEmpty {
            let partURL = try createSplitPart(
                from: sourceDir,
                pages: currentPages,
                partIndex: partIndex,
                originalName: epubURL.deletingPathExtension().lastPathComponent,
                outputDir: tempDir
            )
            splitURLs.append(partURL)
        }
        
        // 4. Move splits to safe location
        var safeURLs: [URL] = []
        for url in splitURLs {
            let safeURL = fileManager.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? fileManager.removeItem(at: safeURL)
            try fileManager.moveItem(at: url, to: safeURL)
            safeURLs.append(safeURL)
        }
        
        return safeURLs
    }
    
    // Helper to create a single split EPUB
    private static func createSplitPart(from sourceDir: URL, pages: [PageItem], partIndex: Int, originalName: String, outputDir: URL) throws -> URL {
        let fileManager = FileManager.default
        let partName = "\(originalName)_Part\(partIndex)"
        let buildDir = outputDir.appendingPathComponent(partName)
        
        // Recreate structure
        let oebpsDir = buildDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        let metaInfDir = buildDir.appendingPathComponent("META-INF")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 1. Copy Static Files (Mimetype, Container, CSS if exists)
        try fileManager.copyItem(at: sourceDir.appendingPathComponent("mimetype"), to: buildDir.appendingPathComponent("mimetype"))
        try fileManager.copyItem(at: sourceDir.appendingPathComponent("META-INF/container.xml"), to: metaInfDir.appendingPathComponent("container.xml"))
        
        let cssSource = sourceDir.appendingPathComponent("OEBPS/styles.css")
        if fileManager.fileExists(atPath: cssSource.path) {
            try fileManager.copyItem(at: cssSource, to: oebpsDir.appendingPathComponent("styles.css"))
        }
        
        // 2. Copy Pages (BINARY COPY)
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, page) in pages.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let xhtmlDest = textDir.appendingPathComponent(URL(fileURLWithPath: page.xhtmlPath).lastPathComponent)
            let imageDest = imagesDir.appendingPathComponent(URL(fileURLWithPath: page.imagePath).lastPathComponent)
            
            // STRICT BINARY COPY - NO PROCESSING
            try fileManager.copyItem(atPath: page.xhtmlPath, toPath: xhtmlDest.path)
            try fileManager.copyItem(atPath: page.imagePath, toPath: imageDest.path)
            
            // Rebuild Manifest Metadata
            let imgName = imageDest.lastPathComponent
            let xhtmlName = xhtmlDest.lastPathComponent
            
            let ext = imageDest.pathExtension.lowercased()
            let mediaType: String
            switch ext {
            case "png": mediaType = "image/png"
            case "gif": mediaType = "image/gif"
            case "webp": mediaType = "image/webp"
            default: mediaType = "image/jpeg"
            }
            
            imageManifest += "<item id=\"img_\(pageNum)\" href=\"images/\(imgName)\" media-type=\"\(mediaType)\"/>\n"
            xhtmlManifest += "<item id=\"page_\(pageNum)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "<itemref idref=\"page_\(pageNum)\"/>\n"
        }
        
        // 3. Generate content.opf
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(originalName) (Part \(partIndex))</dc:title>
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:language>en</dc:language>
                <meta name="cover" content="img_0001"/>
                <meta property="rendition:layout">pre-paginated</meta>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                \(imageManifest)
                \(xhtmlManifest)
            </manifest>
            <spine toc="ncx">
                \(spineItems)
            </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 4. Generate toc.ncx
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="urn:uuid:\(UUID().uuidString)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pages.count)"/>
                <meta name="dtb:maxPageNumber" content="\(pages.count)"/>
            </head>
            <docTitle><text>\(originalName) Part \(partIndex)</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/\(URL(fileURLWithPath: pages.first!.xhtmlPath).lastPathComponent)"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 5. Zip
        let finalEPUB = outputDir.appendingPathComponent("\(partName).epub")
        let archive = try Archive(url: finalEPUB, accessMode: .create)
        
        // Mimetype
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(20), compressionMethod: .none) { position, size in
            return try Data(contentsOf: buildDir.appendingPathComponent("mimetype")).subdata(in: 0..<Int(size))
        }
        
        // Content
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: buildDir, includingPropertiesForKeys: resourceKeys)!
        for case let fileURL as URL in enumerator {
            let path = fileURL.path.replacingOccurrences(of: buildDir.path + "/", with: "")
            if path == "mimetype" || path.isEmpty { continue }
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            if !(values.isDirectory ?? false) {
                let size = UInt32(values.fileSize ?? 0)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(size), compressionMethod: .deflate) { position, size in
                    return try Data(contentsOf: fileURL).subdata(in: 0..<Int(size))
                }
            }
        }
        
        return finalEPUB
    }
}
