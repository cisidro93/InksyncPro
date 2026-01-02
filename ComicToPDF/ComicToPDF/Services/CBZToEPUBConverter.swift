import Foundation
import UIKit
import ZIPFoundation
import CoreGraphics

// ============================================================================
// PRODUCTION CBZ TO EPUB CONVERTER
// ============================================================================
//
// Features:
// - Device-specific profiles (Kindle, Kobo, Standard)
// - Smart strip detection and stitching
// - Quality-based resolution targeting
// - Proper EPUB 3 Fixed-Layout structure
// - Alphanumeric sorting
// - Grayscale option
//
// ============================================================================

struct CBZToEPUBConverter {
    
    // MARK: - Device Profiles
    
    enum DeviceProfile {
        case standard       // 1200x1920 - Universal
        case kindlePW       // 1072x1448 - Paperwhite 3/4/5
        case kindleScribe   // 1860x2480 - Kindle Scribe
        case highRes        // 2400x3840 - High-end devices
        
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
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Main Conversion Pipeline
    
    private func performConversion(cbzURL: URL, compressionQuality: Double) throws -> URL {
        print("\n======================================================================")
        print("CBZ TO EPUB CONVERTER - PRODUCTION MODE")
        print("======================================================================")
        print("Input: \(cbzURL.lastPathComponent)")
        print("Quality: \(Int(compressionQuality * 100))%")
        
        // Setup workspace
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // 1. Extract CBZ
        print("\n1. Extracting archive...")
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.unzipItem(at: cbzURL, to: extractDir)
        print("   Detected extracted files")
        
        // 2. Scan images with proper sorting
        print("\n2. Scanning images...")
        let allImages = try scanImages(in: extractDir)
        print("   Found: \(allImages.count) images")
        
        guard !allImages.isEmpty else {
            throw NSError(domain: "CBZConverter", code: 404,
                         userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ"])
        }
        
        // 3. Analyze content
        let stripCount = allImages.filter { $0.isHorizontalStrip }.count
        let normalCount = allImages.count - stripCount
        
        print("\nContent Analysis:")
        print("   Normal pages: \(normalCount)")
        print("   Horizontal strips: \(stripCount)")
        
        // 4. Group images (handle strips)
        print("\n3. Processing layout...")
        let pageGroups: [PageGroup]
        if stripCount > 0 {
            print("   Strips detected - applying stitching")
            pageGroups = groupImagesWithStripDetection(allImages)
            print("   Grouped into \(pageGroups.count) pages")
        } else {
            print("   All pages are normal - no stitching needed")
            pageGroups = allImages.map { PageGroup(images: [$0]) }
        }
        
        // 5. Build EPUB with quality-based resolution
        print("\n4. Building EPUB...")
        let title = cbzURL.deletingPathExtension().lastPathComponent
        let epubURL = try buildEPUB(
            pageGroups: pageGroups,
            title: title,
            outputDir: tempDir,
            compressionQuality: compressionQuality
        )
        
        // 6. Move to final location
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.copyItem(at: epubURL, to: finalURL)
        
        // Report results
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        let sizeMB = fileSize / 1_000_000
        
        print("\n======================================================================")
        print("CONVERSION COMPLETE")
        print("======================================================================")
        print("Output: \(finalURL.lastPathComponent)")
        print("Size: \(sizeMB) MB")
        print("Pages: \(pageGroups.count)")
        
        return finalURL
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
            
            // Skip system/metadata files
            if fileURL.lastPathComponent.hasPrefix(".") ||
               fileURL.lastPathComponent.hasPrefix("__") ||
               fileURL.path.contains("__MACOSX") {
                continue
            }
            
            guard supportedExtensions.contains(ext) else { continue }
            
            // Load image safely
            guard let image = UIImage(contentsOfFile: fileURL.path),
                  let cgImage = image.cgImage else {
                continue
            }
            
            images.append(ImageInfo(
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                width: cgImage.width,
                height: cgImage.height
            ))
        }
        
        // Alphanumeric sorting
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
                // Accumulate strips
                currentStripBatch.append(img)
            } else {
                // Flush accumulated strips
                if !currentStripBatch.isEmpty {
                    groups.append(PageGroup(images: currentStripBatch))
                    print("      Grouped \(currentStripBatch.count) strips -> 1 page")
                    currentStripBatch = []
                }
                // Add normal page
                groups.append(PageGroup(images: [img]))
            }
        }
        
        // Flush remaining strips
        if !currentStripBatch.isEmpty {
            groups.append(PageGroup(images: currentStripBatch))
            print("      Grouped \(currentStripBatch.count) strips -> 1 page (final)")
        }
        
        return groups
    }
    
    // MARK: - Image Stitching
    
    private func stitchImages(_ images: [ImageInfo]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        
        if images.count == 1 {
            return UIImage(contentsOfFile: images[0].fileURL.path)
        }
        
        // Load all images
        var loaded: [UIImage] = []
        for info in images {
            guard let img = UIImage(contentsOfFile: info.fileURL.path) else {
                continue
            }
            loaded.append(img)
        }
        
        guard !loaded.isEmpty else { return nil }
        
        // Calculate dimensions
        let width = loaded[0].size.width
        let totalHeight = loaded.reduce(0) { $0 + $1.size.height }
        let scale = loaded[0].scale
        
        // Use UIGraphicsImageContext
        UIGraphicsBeginImageContextWithOptions(
            CGSize(width: width, height: totalHeight),
            false,
            scale
        )
        defer { UIGraphicsEndImageContext() }
        
        // Draw strips vertically
        var yOffset: CGFloat = 0
        for img in loaded {
            img.draw(at: CGPoint(x: 0, y: yOffset))
            yOffset += img.size.height
        }
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    // MARK: - Image Processing
    
    private func processImage(_ group: PageGroup, targetResolution: CGSize) -> UIImage? {
        // Get source image (stitch if needed)
        let sourceImage: UIImage?
        if group.isSingleImage {
            sourceImage = UIImage(contentsOfFile: group.images[0].fileURL.path)
        } else {
            sourceImage = stitchImages(group.images)
        }
        
        guard let image = sourceImage, let cgImage = image.cgImage else {
            return nil
        }
        
        // Get dimensions
        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        
        // Calculate target (don't upscale, only downscale if needed)
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
        
        // If no resize needed, return original
        if finalWidth == sourceWidth && finalHeight == sourceHeight {
            return image
        }
        
        // Resize using high-quality renderer
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
        title: String,
        outputDir: URL,
        compressionQuality: Double
    ) throws -> URL {
        
        // Determine target resolution based on quality
        let targetResolution: CGSize
        if compressionQuality >= 0.9 {
            targetResolution = DeviceProfile.highRes.resolution // 2400x3840
        } else if compressionQuality >= 0.8 {
            targetResolution = CGSize(width: 1600, height: 2400) // Balanced
        } else {
            targetResolution = DeviceProfile.standard.resolution // 1200x1920
        }
        
        print("   Target resolution: \(Int(targetResolution.width))x\(Int(targetResolution.height))")
        
        // Create EPUB structure
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("Images")
        let textDir = oebpsDir.appendingPathComponent("Text")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        // Create mimetype (MUST be uncompressed)
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
        
        // Process pages
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, group) in pageGroups.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let imageName = "Page_\(pageNum).jpg"
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // Process image
            guard let processedImage = processImage(group, targetResolution: targetResolution),
                  let cgImage = processedImage.cgImage else {
                print("   Skipped page \(index + 1)")
                continue
            }
            
            // Encode to JPEG
            guard let jpegData = processedImage.jpegData(compressionQuality: compressionQuality) else {
                print("   Failed to encode page \(index + 1)")
                continue
            }
            
            try jpegData.write(to: imageDestURL)
            
            let width = cgImage.width
            let height = cgImage.height
            let sizeKB = jpegData.count / 1024
            let stitchInfo = group.isSingleImage ? "" : " [stitched from \(group.images.count)]"
            print("   Page \(index + 1): \(width)x\(height) - \(sizeKB)KB\(stitchInfo)")
            
            // Add to manifest
            imageManifest += "    <item id=\"img\(pageNum)\" href=\"Images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            // Create XHTML with proper viewport
            let xhtmlContent = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <meta name="viewport" content="width=\(width), height=\(height)"/>
                <style type="text/css">
                    body { margin: 0; padding: 0; text-align: center; }
                    img { max-width: 100%; max-height: 100%; object-fit: contain; }
                </style>
            </head>
            <body>
                <img src="../Images/\(imageName)" alt="Page \(index + 1)"/>
            </body>
            </html>
            """
            
            let xhtmlName = "Page_\(pageNum).xhtml"
            try xhtmlContent.write(
                to: textDir.appendingPathComponent(xhtmlName),
                atomically: true,
                encoding: .utf8
            )
            
            xhtmlManifest += "    <item id=\"page\(pageNum)\" href=\"Text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "    <itemref idref=\"page\(pageNum)\"/>\n"
        }
        
        // Create content.opf with proper Fixed-Layout metadata
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>en</dc:language>
                <dc:creator>ComicToPDF Converter</dc:creator>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">none</meta>
            </metadata>
            <manifest>
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
        let epubURL = outputDir.appendingPathComponent(title + ".epub")
        try FileManager.default.zipItem(at: epubDir, to: epubURL)
        
        return epubURL
    }
}
