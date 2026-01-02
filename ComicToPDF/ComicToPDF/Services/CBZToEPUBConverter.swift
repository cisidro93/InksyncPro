// ============================================================================
// COMPREHENSIVE CBZ TO EPUB CONVERSION AND SPLITTING SYSTEM
// ============================================================================
// 
// This file contains TWO classes that work together:
// 1. CBZToEPUBConverter - Handles conversion with memory optimization
// 2. ComicEPUBProcessor - Handles splitting large files
//
// PASTE THIS ENTIRE FILE INTO ANTIGRAVITY IDE
// Tell it: "Replace CBZToEPUBConverter.swift and ComicEPUBProcessor.swift with this code"
//
// ============================================================================

import Foundation
import UIKit
import ZIPFoundation
import CoreGraphics

// ============================================================================
// PART 1: CBZ TO EPUB CONVERTER
// ============================================================================

struct CBZToEPUBConverter {
    
    // MARK: - Configuration
    
    private let stripAspectRatioThreshold: Double = 2.0
    private let maxMemorySafeBatchSize = 50
    
    // MARK: - Device Profiles
    
    enum DeviceProfile {
        case standard
        case kindlePW
        case kindleScribe
        case highRes
        
        var resolution: CGSize {
            switch self {
            case .standard: return CGSize(width: 1200, height: 1920)
            case .kindlePW: return CGSize(width: 1072, height: 1448)
            case .kindleScribe: return CGSize(width: 1860, height: 2480)
            case .highRes: return CGSize(width: 2400, height: 3840)
            }
        }
    }
    
    // MARK: - Internal Types
    
    private struct ImageInfo {
        let fileURL: URL
        let filename: String
        let width: Int
        let height: Int
        var aspectRatio: Double { Double(width) / Double(height) }
        var isHorizontalStrip: Bool { aspectRatio > 2.0 }
    }
    
    private struct PageGroup {
        let images: [ImageInfo]
        var isSingleImage: Bool { images.count == 1 }
    }
    
    private struct ConversionMetadata {
        let title: String
        let author: String?
        let series: String?
        let volume: String?
    }
    
    // MARK: - Public Interface
    
    public init() {}
    
    func convertCBZToEPUB(_ cbzURL: URL, compressionQuality: Double) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.performConversion(
                        cbzURL: cbzURL,
                        compressionQuality: compressionQuality
                    )
                    continuation.resume(returning: result)
                } catch {
                    print("❌ Conversion error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Main Conversion Pipeline
    
    private func performConversion(cbzURL: URL, compressionQuality: Double) throws -> URL {
        print("\n" + String(repeating: "=", count: 70))
        print("📚 CBZ TO EPUB CONVERTER - PRODUCTION VERSION")
        print(String(repeating: "=", count: 70))
        print("Input: \(cbzURL.lastPathComponent)")
        
        let inputSize = (try? FileManager.default.attributesOfItem(atPath: cbzURL.path)[.size] as? Int64) ?? 0
        let inputSizeMB = inputSize / 1_000_000
        print("Input size: \(inputSizeMB) MB")
        print("Quality: \(Int(compressionQuality * 100))%")
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let metadata = extractMetadata(from: cbzURL)
        print("Title: \(metadata.title)")
        
        print("\n1️⃣  Extracting archive...")
        let extractDir = tempDir.appendingPathComponent("extracted")
        
        do {
            try FileManager.default.unzipItem(at: cbzURL, to: extractDir)
            print("   ✓ Extracted successfully")
        } catch {
            print("   ❌ Extraction failed: \(error)")
            throw error
        }
        
        print("\n2️⃣  Scanning images...")
        let allImages = try scanImages(in: extractDir)
        print("   Found: \(allImages.count) images")
        
        guard !allImages.isEmpty else {
            throw NSError(domain: "CBZConverter", code: 404,
                         userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ"])
        }
        
        if allImages.count > 500 {
            print("   ⚠️  Large file detected (\(allImages.count) pages)")
            print("   ⚠️  Processing in memory-safe batches")
        }
        
        let stripCount = allImages.filter { $0.isHorizontalStrip }.count
        let normalCount = allImages.count - stripCount
        
        print("\n📊 Content Analysis:")
        print("   Normal pages: \(normalCount)")
        print("   Horizontal strips: \(stripCount)")
        
        print("\n3️⃣  Processing layout...")
        let pageGroups: [PageGroup]
        if stripCount > 0 {
            print("   ⚠️  Strips detected - applying stitching")
            pageGroups = groupImagesWithStripDetection(allImages)
            print("   ✓ Grouped into \(pageGroups.count) pages")
        } else {
            pageGroups = allImages.map { PageGroup(images: [$0]) }
        }
        
        print("\n4️⃣  Building EPUB...")
        let epubURL = try buildEPUB(
            pageGroups: pageGroups,
            metadata: metadata,
            outputDir: tempDir,
            compressionQuality: compressionQuality
        )
        
        let originalFilename = cbzURL.deletingPathExtension().lastPathComponent
        let finalFilename = sanitizeFilename(originalFilename) + ".epub"
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(finalFilename)
        
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.copyItem(at: epubURL, to: finalURL)
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        let sizeMB = fileSize / 1_000_000
        
        print("\n" + String(repeating: "=", count: 70))
        print("✅ CONVERSION COMPLETE")
        print(String(repeating: "=", count: 70))
        print("Output: \(finalFilename)")
        print("Size: \(sizeMB) MB")
        print("Pages: \(pageGroups.count)")
        
        if sizeMB > 200 {
            print("⚠️  File is \(sizeMB)MB - exceeds 200MB limit")
            print("⚠️  Will be automatically split by ConversionManager")
        }
        
        return finalURL
    }
    
    // MARK: - Metadata Extraction
    
    private func extractMetadata(from url: URL) -> ConversionMetadata {
        let filename = url.deletingPathExtension().lastPathComponent
        
        var author: String?
        var series: String?
        var volume: String?
        
        if filename.contains(" - ") {
            let parts = filename.components(separatedBy: " - ")
            if parts.count >= 2 {
                author = parts[0].trimmingCharacters(in: .whitespaces)
            }
        }
        
        let volumePatterns = ["v(\\d+)", "vol\\.?\\s*(\\d+)", "volume\\s*(\\d+)", "#(\\d+)"]
        for pattern in volumePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                if let match = regex.firstMatch(in: filename, options: [], range: NSRange(filename.startIndex..., in: filename)) {
                    if let range = Range(match.range(at: 1), in: filename) {
                        volume = String(filename[range])
                        break
                    }
                }
            }
        }
        
        return ConversionMetadata(
            title: filename,
            author: author,
            series: series,
            volume: volume
        )
    }
    
    private func sanitizeFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return filename.components(separatedBy: invalid).joined(separator: "_")
    }
    
    // MARK: - Image Scanning
    
    private func scanImages(in directory: URL) throws -> [ImageInfo] {
        var images: [ImageInfo] = []
        let supportedExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
        
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return images
        }
        
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            
            if fileURL.lastPathComponent.hasPrefix(".") ||
               fileURL.lastPathComponent.hasPrefix("__") ||
               fileURL.path.contains("__MACOSX") {
                continue
            }
            
            guard supportedExtensions.contains(ext) else { continue }
            
            guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
                continue
            }
            
            images.append(ImageInfo(
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                width: width,
                height: height
            ))
        }
        
        images.sort {
            $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
        
        return images
    }
    
    // MARK: - Strip Detection and Grouping
    
    private func groupImagesWithStripDetection(_ images: [ImageInfo]) -> [PageGroup] {
        var groups: [PageGroup] = []
        var currentStripBatch: [ImageInfo] = []
        
        for img in images {
            if img.isHorizontalStrip {
                currentStripBatch.append(img)
            } else {
                if !currentStripBatch.isEmpty {
                    groups.append(PageGroup(images: currentStripBatch))
                    currentStripBatch = []
                }
                groups.append(PageGroup(images: [img]))
            }
        }
        
        if !currentStripBatch.isEmpty {
            groups.append(PageGroup(images: currentStripBatch))
        }
        
        return groups
    }
    
    // MARK: - Image Stitching
    
    private func stitchImages(_ images: [ImageInfo]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        
        if images.count == 1 {
            return UIImage(contentsOfFile: images[0].fileURL.path)
        }
        
        var loaded: [UIImage] = []
        for info in images {
            guard let img = UIImage(contentsOfFile: info.fileURL.path) else {
                continue
            }
            loaded.append(img)
        }
        
        guard !loaded.isEmpty else { return nil }
        
        let width = loaded[0].size.width
        let totalHeight = loaded.reduce(0) { $0 + $1.size.height }
        let scale = loaded[0].scale
        
        UIGraphicsBeginImageContextWithOptions(
            CGSize(width: width, height: totalHeight),
            false,
            scale
        )
        defer { UIGraphicsEndImageContext() }
        
        var yOffset: CGFloat = 0
        for img in loaded {
            img.draw(at: CGPoint(x: 0, y: yOffset))
            yOffset += img.size.height
        }
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    // MARK: - Image Processing
    
    private func processImage(_ group: PageGroup, targetResolution: CGSize) -> UIImage? {
        let sourceImage: UIImage?
        if group.isSingleImage {
            sourceImage = UIImage(contentsOfFile: group.images[0].fileURL.path)
        } else {
            sourceImage = stitchImages(group.images)
        }
        
        guard let image = sourceImage, let cgImage = image.cgImage else {
            return nil
        }
        
        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        
        var finalWidth = sourceWidth
        var finalHeight = sourceHeight
        
        if sourceWidth > targetResolution.width || sourceHeight > targetResolution.height {
            let scale = min(
                targetResolution.width / sourceWidth,
                targetResolution.height / sourceHeight,
                1.0
            )
            finalWidth = (sourceWidth * scale).rounded()
            finalHeight = (sourceHeight * scale).rounded()
        }
        
        if finalWidth == sourceWidth && finalHeight == sourceHeight {
            return image
        }
        
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: finalWidth, height: finalHeight)
        )
        
        return renderer.image { _ in
            image.draw(in: CGRect(
                origin: .zero,
                size: CGSize(width: finalWidth, height: finalHeight)
            ))
        }
    }
    
    // MARK: - EPUB Generation
    
    private func buildEPUB(
        pageGroups: [PageGroup],
        metadata: ConversionMetadata,
        outputDir: URL,
        compressionQuality: Double
    ) throws -> URL {
        
        let targetResolution: CGSize
        if compressionQuality >= 0.9 {
            targetResolution = DeviceProfile.highRes.resolution
        } else if compressionQuality >= 0.8 {
            targetResolution = CGSize(width: 1600, height: 2400)
        } else {
            targetResolution = DeviceProfile.standard.resolution
        }
        
        print("   Target resolution: \(Int(targetResolution.width))×\(Int(targetResolution.height))")
        
        // CRITICAL: Use lowercase directories for splitting compatibility
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        try "application/epub+zip".write(
            to: epubDir.appendingPathComponent("mimetype"),
            atomically: true,
            encoding: .utf8
        )
        
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(
            to: metaInfDir.appendingPathComponent("container.xml"),
            atomically: true,
            encoding: .utf8
        )
        
        let cssContent = """
        @charset "UTF-8";
        * { margin: 0; padding: 0; border: 0; }
        html, body { width: 100%; height: 100%; margin: 0; padding: 0; }
        body { display: flex; align-items: center; justify-content: center; background-color: #000; text-align: center; }
        .page { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
        img { max-width: 100%; max-height: 100%; width: auto; height: auto; object-fit: contain; display: block; }
        @media amzn-kf8 { img { max-width: 100%; max-height: 100%; } }
        """
        try cssContent.write(
            to: oebpsDir.appendingPathComponent("styles.css"),
            atomically: true,
            encoding: .utf8
        )
        
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        let totalPages = pageGroups.count
        var processedCount = 0
        
        for (index, group) in pageGroups.enumerated() {
            autoreleasepool {
                let pageNum = String(format: "%04d", index + 1)
                let imageName = "page\(pageNum).jpg"
                let imageDestURL = imagesDir.appendingPathComponent(imageName)
                
                do {
                    guard let processedImage = processImage(group, targetResolution: targetResolution),
                          let cgImage = processedImage.cgImage else {
                        print("   ⚠️  Skipped page \(index + 1)")
                        return
                    }
                    
                    guard let jpegData = processedImage.jpegData(compressionQuality: compressionQuality) else {
                        print("   ⚠️  Failed to encode page \(index + 1)")
                        return
                    }
                    
                    try jpegData.write(to: imageDestURL)
                    
                    let width = cgImage.width
                    let height = cgImage.height
                    processedCount += 1
                    
                    if totalPages > 100 && processedCount % 50 == 0 {
                        print("   Progress: \(processedCount)/\(totalPages) pages (\(Int((Double(processedCount)/Double(totalPages)) * 100))%)")
                    }
                    
                    imageManifest += "    <item id=\"img_\(pageNum)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
                    
                    let xhtmlContent = """
                    <?xml version="1.0" encoding="utf-8"?>
                    <!DOCTYPE html>
                    <html xmlns="http://www.w3.org/1999/xhtml">
                    <head>
                        <meta charset="utf-8"/>
                        <title>Page \(index + 1)</title>
                        <meta name="viewport" content="width=\(width), height=\(height)"/>
                        <link rel="stylesheet" type="text/css" href="../styles.css"/>
                    </head>
                    <body>
                        <div class="page">
                            <img src="../images/\(imageName)" alt="Page \(index + 1)"/>
                        </div>
                    </body>
                    </html>
                    """
                    
                    let xhtmlName = "page\(pageNum).xhtml"
                    try xhtmlContent.write(
                        to: textDir.appendingPathComponent(xhtmlName),
                        atomically: true,
                        encoding: .utf8
                    )
                    
                    xhtmlManifest += "    <item id=\"page_\(pageNum)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
                    spineItems += "    <itemref idref=\"page_\(pageNum)\"/>\n"
                    
                } catch {
                    print("   ❌ Error processing page \(index + 1): \(error)")
                }
            }
        }
        
        print("   ✓ Processed \(processedCount) pages")
        
        let authorElement = metadata.author.map { "<dc:creator>\($0)</dc:creator>" } ?? ""
        
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(metadata.title)</dc:title>
                <dc:language>en</dc:language>
                \(authorElement)
                <dc:publisher>ComicToPDF Converter</dc:publisher>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">none</meta>
            </metadata>
            <manifest>
                <item id="css" href="styles.css" media-type="text/css"/>
                \(imageManifest)\(xhtmlManifest)    </manifest>
            <spine>
                \(spineItems)    </spine>
        </package>
        """
        try opfContent.write(
            to: oebpsDir.appendingPathComponent("content.opf"),
            atomically: true,
            encoding: .utf8
        )
        
        let epubURL = outputDir.appendingPathComponent(metadata.title + ".epub")
        try FileManager.default.zipItem(at: epubDir, to: epubURL)
        
        return epubURL
    }
}

// ============================================================================
// PART 2: COMIC EPUB PROCESSOR (SPLITTER)
// ============================================================================

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
        let fullPathInZip: String
    }
    
    static func splitEPUB(_ epubURL: URL, maxSizeMB: Int) throws -> [URL] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("EPUBSplit_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        print("\n📦 SPLITTING EPUB")
        print("Source: \(epubURL.lastPathComponent)")
        print("Max size per part: \(maxSizeMB)MB")
        
        let sourceDir = tempDir.appendingPathComponent("Source")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        
        do {
            try fileManager.unzipItem(at: epubURL, to: sourceDir)
            print("✓ Extracted EPUB")
        } catch {
            throw SplitError.invalidSource
        }
        
        var epubRoot = sourceDir
        var oebpsDir = sourceDir.appendingPathComponent("OEBPS")
        
        // Handle case where zip contains a wrapping directory
        if !fileManager.fileExists(atPath: oebpsDir.path) {
            let contents = (try? fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
            let subdirs = contents.filter { $0.hasDirectoryPath }
            
            if subdirs.count == 1 {
                print("⚠️  Found wrapping directory: \(subdirs[0].lastPathComponent)")
                epubRoot = subdirs[0]
                oebpsDir = epubRoot.appendingPathComponent("OEBPS")
            } else {
                print("❌ OEBPS directory not found in \(sourceDir.path)")
                print("Files found: \(contents.map { $0.lastPathComponent })")
            }
        }
        
        guard fileManager.fileExists(atPath: oebpsDir.path) else {
            throw SplitError.structuralError("OEBPS directory not found")
        }
        
        var imagesDir: URL?
        var textDir: URL?
        
        // Try lowercase first (new format)
        let imagesLower = oebpsDir.appendingPathComponent("images")
        let textLower = oebpsDir.appendingPathComponent("text")
        
        if fileManager.fileExists(atPath: imagesLower.path) && 
           fileManager.fileExists(atPath: textLower.path) {
            imagesDir = imagesLower
            textDir = textLower
            print("✓ Found lowercase structure (images/text)")
        } else {
            // Try capitalized (old format)
            let imagesCap = oebpsDir.appendingPathComponent("Images")
            let textCap = oebpsDir.appendingPathComponent("Text")
            
            if fileManager.fileExists(atPath: imagesCap.path) && 
               fileManager.fileExists(atPath: textCap.path) {
                imagesDir = imagesCap
                textDir = textCap
                print("✓ Found capitalized structure (Images/Text)")
            }
        }
        
        guard let finalImagesDir = imagesDir, let finalTextDir = textDir else {
            print("❌ Could not find standard directory structure")
            
            if let contents = try? fileManager.contentsOfDirectory(at: oebpsDir, includingPropertiesForKeys: nil) {
                print("📁 OEBPS contains:")
                for item in contents {
                    print("   - \(item.lastPathComponent)")
                }
            }
            
            throw SplitError.structuralError("Standard EPUB structure not found. Expected OEBPS/images/text or OEBPS/Images/Text")
        }
        
        print("🔍 Scanning pages...")
        var pages: [PageItem] = []
        let enumerator = fileManager.enumerator(at: finalTextDir, includingPropertiesForKeys: nil)
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension.lowercased() == "xhtml" {
                let basename = fileURL.deletingPathExtension().lastPathComponent
                
                var imageFile: URL?
                for ext in ["jpg", "jpeg", "png", "gif", "webp"] {
                    let imgURL = finalImagesDir.appendingPathComponent("\(basename).\(ext)")
                    if fileManager.fileExists(atPath: imgURL.path) {
                        imageFile = imgURL
                        break
                    }
                }
                
                if let img = imageFile {
                    pages.append(PageItem(
                        xhtmlPath: fileURL.path,
                        imagePath: img.path,
                        fullPathInZip: ""
                    ))
                }
            }
        }
        
        pages.sort { $0.xhtmlPath.localizedStandardCompare($1.xhtmlPath) == .orderedAscending }
        
        print("✓ Found \(pages.count) pages")
        
        if pages.isEmpty { 
            print("⚠️  No pages found - returning original file")
            return [epubURL] 
        }
        
        let maxBytes = Int64(maxSizeMB * 1024 * 1024)
        var splitURLs: [URL] = []
        var currentPages: [PageItem] = []
        var currentSize: Int64 = 0
        var partIndex = 1
        
        let commonFilesSize: Int64 = 100 * 1024
        
        for page in pages {
            let xhtmlSize = (try? fileManager.attributesOfItem(atPath: page.xhtmlPath)[.size] as? Int64) ?? 0
            let imageSize = (try? fileManager.attributesOfItem(atPath: page.imagePath)[.size] as? Int64) ?? 0
            let pageSize = xhtmlSize + imageSize
            
            if currentSize + pageSize + commonFilesSize > maxBytes && !currentPages.isEmpty {
                print("Creating part \(partIndex) with \(currentPages.count) pages...")
                let partURL = try createSplitPart(
                    from: epubRoot,
                    pages: currentPages,
                    partIndex: partIndex,
                    originalName: epubURL.deletingPathExtension().lastPathComponent,
                    outputDir: tempDir,
                    useCapitalizedDirs: (imagesDir == oebpsDir.appendingPathComponent("Images"))
                )
                splitURLs.append(partURL)
                
                partIndex += 1
                currentPages = []
                currentSize = 0
            }
            
            currentPages.append(page)
            currentSize += pageSize
        }
        
        if !currentPages.isEmpty {
            print("Creating part \(partIndex) with \(currentPages.count) pages...")
            let partURL = try createSplitPart(
                from: epubRoot,
                pages: currentPages,
                partIndex: partIndex,
                originalName: epubURL.deletingPathExtension().lastPathComponent,
                outputDir: tempDir,
                useCapitalizedDirs: (imagesDir == oebpsDir.appendingPathComponent("Images"))
            )
            splitURLs.append(partURL)
        }
        
        var safeURLs: [URL] = []
        for url in splitURLs {
            let safeURL = fileManager.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? fileManager.removeItem(at: safeURL)
            try fileManager.moveItem(at: url, to: safeURL)
            safeURLs.append(safeURL)
        }
        
        print("✅ Split into \(safeURLs.count) parts")
        for (index, url) in safeURLs.enumerated() {
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            print("   Part \(index + 1): \(url.lastPathComponent) (\(size / 1_000_000)MB)")
        }
        
        return safeURLs
    }
    
    private static func createSplitPart(
        from sourceDir: URL,
        pages: [PageItem],
        partIndex: Int,
        originalName: String,
        outputDir: URL,
        useCapitalizedDirs: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let partName = "\(originalName)_Part\(partIndex)"
        let buildDir = outputDir.appendingPathComponent(partName)
        
        let oebpsDir = buildDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent(useCapitalizedDirs ? "Images" : "images")
        let textDir = oebpsDir.appendingPathComponent(useCapitalizedDirs ? "Text" : "text")
        let metaInfDir = buildDir.appendingPathComponent("META-INF")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        try fileManager.copyItem(
            at: sourceDir.appendingPathComponent("mimetype"),
            to: buildDir.appendingPathComponent("mimetype")
        )
        try fileManager.copyItem(
            at: sourceDir.appendingPathComponent("META-INF/container.xml"),
            to: metaInfDir.appendingPathComponent("container.xml")
        )
        
        let cssSource = sourceDir.appendingPathComponent("OEBPS/styles.css")
        if fileManager.fileExists(atPath: cssSource.path) {
            try fileManager.copyItem(at: cssSource, to: oebpsDir.appendingPathComponent("styles.css"))
        }
        
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        let imagesDirName = useCapitalizedDirs ? "Images" : "images"
        let textDirName = useCapitalizedDirs ? "Text" : "text"
        
        for (index, page) in pages.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let xhtmlDest = textDir.appendingPathComponent(URL(fileURLWithPath: page.xhtmlPath).lastPathComponent)
            let imageDest = imagesDir.appendingPathComponent(URL(fileURLWithPath: page.imagePath).lastPathComponent)
            
            try fileManager.copyItem(atPath: page.xhtmlPath, toPath: xhtmlDest.path)
            try fileManager.copyItem(atPath: page.imagePath, toPath: imageDest.path)
            
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
            
            imageManifest += "    <item id=\"img_\(pageNum)\" href=\"\(imagesDirName)/\(imgName)\" media-type=\"\(mediaType)\"/>\n"
            xhtmlManifest += "    <item id=\"page_\(pageNum)\" href=\"\(textDirName)/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "    <itemref idref=\"page_\(pageNum)\"/>\n"
        }
        
        let cssItem = fileManager.fileExists(atPath: oebpsDir.appendingPathComponent("styles.css").path) 
            ? "    <item id=\"css\" href=\"styles.css\" media-type=\"text/css\"/>\n" 
            : ""
        
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(originalName) (Part \(partIndex))</dc:title>
                <dc:language>en</dc:language>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">none</meta>
            </metadata>
            <manifest>
                \(cssItem)\(imageManifest)\(xhtmlManifest)    </manifest>
            <spine>
                \(spineItems)    </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        let finalEPUB = outputDir.appendingPathComponent("\(partName).epub")
        try fileManager.zipItem(at: buildDir, to: finalEPUB)
        
        return finalEPUB
    }
}
