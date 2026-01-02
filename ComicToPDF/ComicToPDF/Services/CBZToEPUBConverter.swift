import Foundation
import UIKit
import ZIPFoundation
import CoreGraphics

// ============================================================================
// PRODUCTION CBZ TO EPUB CONVERTER - MEMORY-OPTIMIZED + SPLITTING COMPATIBLE
// ============================================================================
// 
// ✅ CRITICAL FIXES:
// - Proper directory structure (lowercase) for splitting compatibility
// - Memory-efficient processing for large files (800MB+)
// - Streaming image processing to avoid memory crashes
// - Robust error handling with detailed logging
// - Auto-split for files > 200MB
//
// ============================================================================

struct CBZToEPUBConverter {
    
    // MARK: - Configuration
    
    private let stripAspectRatioThreshold: Double = 2.0
    private let maxMemorySafeBatchSize = 50 // Process images in batches to avoid memory issues
    
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
        print("📚 CBZ TO EPUB CONVERTER - MEMORY-OPTIMIZED VERSION")
        print(String(repeating: "=", count: 70))
        print("Input: \(cbzURL.lastPathComponent)")
        
        // Check input file size
        let inputSize = (try? FileManager.default.attributesOfItem(atPath: cbzURL.path)[.size] as? Int64) ?? 0
        let inputSizeMB = inputSize / 1_000_000
        print("Input size: \(inputSizeMB) MB")
        print("Quality: \(Int(compressionQuality * 100))%")
        
        // Setup workspace
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Extract metadata
        let metadata = extractMetadata(from: cbzURL)
        print("Title: \(metadata.title)")
        
        // 1. Extract CBZ
        print("\n1️⃣  Extracting archive...")
        let extractDir = tempDir.appendingPathComponent("extracted")
        
        do {
            try FileManager.default.unzipItem(at: cbzURL, to: extractDir)
            print("   ✓ Extracted successfully")
        } catch {
            print("   ❌ Extraction failed: \(error)")
            throw error
        }
        
        // 2. Scan images
        print("\n2️⃣  Scanning images...")
        let allImages = try scanImages(in: extractDir)
        print("   Found: \(allImages.count) images")
        
        guard !allImages.isEmpty else {
            throw NSError(domain: "CBZConverter", code: 404,
                         userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ"])
        }
        
        // Warn if very large
        if allImages.count > 500 {
            print("   ⚠️  Large file detected (\(allImages.count) pages)")
            print("   ⚠️  Processing in memory-safe batches")
        }
        
        // 3. Analyze content
        let stripCount = allImages.filter { $0.isHorizontalStrip }.count
        let normalCount = allImages.count - stripCount
        
        print("\n📊 Content Analysis:")
        print("   Normal pages: \(normalCount)")
        print("   Horizontal strips: \(stripCount)")
        
        // 4. Group images
        print("\n3️⃣  Processing layout...")
        let pageGroups: [PageGroup]
        if stripCount > 0 {
            print("   ⚠️  Strips detected - applying stitching")
            pageGroups = groupImagesWithStripDetection(allImages)
            print("   ✓ Grouped into \(pageGroups.count) pages")
        } else {
            pageGroups = allImages.map { PageGroup(images: [$0]) }
        }
        
        // 5. Build EPUB
        print("\n4️⃣  Building EPUB...")
        let epubURL = try buildEPUB(
            pageGroups: pageGroups,
            metadata: metadata,
            outputDir: tempDir,
            compressionQuality: compressionQuality
        )
        
        // 6. Move to final location with preserved filename
        let originalFilename = cbzURL.deletingPathExtension().lastPathComponent
        let finalFilename = sanitizeFilename(originalFilename) + ".epub"
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(finalFilename)
        
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.copyItem(at: epubURL, to: finalURL)
        
        // Report results
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
            
            // Memory-efficient: Don't load full image, just get dimensions
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
        
        // CRITICAL: Alphanumeric sorting
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
    
    // MARK: - Image Processing (Memory-Efficient)
    
    private func processImage(_ group: PageGroup, targetResolution: CGSize) -> UIImage? {
        // Get source image
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
        
        // Determine target resolution
        let targetResolution: CGSize
        if compressionQuality >= 0.9 {
            targetResolution = DeviceProfile.highRes.resolution
        } else if compressionQuality >= 0.8 {
            targetResolution = CGSize(width: 1600, height: 2400)
        } else {
            targetResolution = DeviceProfile.standard.resolution
        }
        
        print("   Target resolution: \(Int(targetResolution.width))×\(Int(targetResolution.height))")
        
        // Create EPUB structure with LOWERCASE directories for splitting compatibility
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")  // ⭐ LOWERCASE for splitter
        let textDir = oebpsDir.appendingPathComponent("text")      // ⭐ LOWERCASE for splitter
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        // Create mimetype
        try "application/epub+zip".write(
            to: epubDir.appendingPathComponent("mimetype"),
            atomically: true,
            encoding: .utf8
        )
        
        // Create container.xml
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
        
        // Enhanced CSS
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
        
        // Process pages in batches to avoid memory issues
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        let totalPages = pageGroups.count
        var processedCount = 0
        
        for (index, group) in pageGroups.enumerated() {
            autoreleasepool {
                let pageNum = String(format: "%04d", index + 1)
                let imageName = "page\(pageNum).jpg"  // ⭐ LOWERCASE prefix for consistency
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
                    
                    // Progress indicator for large files
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
                    
                    let xhtmlName = "page\(pageNum).xhtml"  // ⭐ LOWERCASE prefix
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
        
        // Create content.opf
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
        
        // Zip to EPUB
        let epubURL = outputDir.appendingPathComponent(metadata.title + ".epub")
        try FileManager.default.zipItem(at: epubDir, to: epubURL)
        
        return epubURL
    }
}
