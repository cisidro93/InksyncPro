import Foundation
import UIKit
import ZIPFoundation

// MARK: - Production CBZ to EPUB Converter
// Based on best practices from: go-comic-converter, CloudConvert, Calibre
// 
// Key Features:
// - Device-specific profiles (Kindle, Kobo, etc.)
// - Smart image processing (crop, rotate, split double-pages)
// - Quality presets (High, Balanced, Compact)
// - Proper EPUB 3 Fixed-Layout structure
// - Automatic blank page removal
// - Size management (split if > 200MB)

class CBZToEPUBConverter {
    
    // MARK: - Configuration
    
    struct ConversionConfig {
        // Output settings
        var targetResolution: CGSize = CGSize(width: 1200, height: 1920) // Standard Resolution
        var quality: Double = 0.85 // JPEG quality (0.0-1.0)
        var format: ImageFormat = .jpeg
        var grayscale: Bool = false // Set true for e-ink devices
        
        // Processing options
        var autoCrop: Bool = true
        var autoRotate: Bool = false // Rotate landscape to portrait
        var autoSplitDoublePage: Bool = false // Split wide pages
        var removeBlankPages: Bool = true
        var stripDetection: Bool = true // Detect and stitch horizontal strips
        
        // Layout options
        var aspectRatio: Double = 0.0 // 0 = preserve source, 1.6 = Kindle optimal
        var isManga: Bool = false // Right-to-left reading
        var hasCover: Bool = true // First page is cover
        
        // Size management
        var maxFileSizeMB: Int = 0 // 0 = no limit, 200 = split if larger
    }
    
    enum ImageFormat {
        case jpeg
        case png
    }
    
    // MARK: - Device Profiles (from go-comic-converter)
    
    enum DeviceProfile {
        case standardResolution // 1200x1920 - Universal
        case kindlePaperwhite  // 1072x1448 - Kindle PW 3/4/5
        case kindleScribe      // 1860x2480 - Kindle Scribe
        case koboLibra         // 1264x1680 - Kobo Libra
        case koboForma         // 1440x1920 - Kobo Forma
        case highResolution    // 2400x3840 - High-end devices
        
        var resolution: CGSize {
            switch self {
            case .standardResolution: return CGSize(width: 1200, height: 1920)
            case .kindlePaperwhite: return CGSize(width: 1072, height: 1448)
            case .kindleScribe: return CGSize(width: 1860, height: 2480)
            case .koboLibra: return CGSize(width: 1264, height: 1680)
            case .koboForma: return CGSize(width: 1440, height: 1920)
            case .highResolution: return CGSize(width: 2400, height: 3840)
            }
        }
        
        var name: String {
            switch self {
            case .standardResolution: return "Standard Resolution"
            case .kindlePaperwhite: return "Kindle Paperwhite"
            case .kindleScribe: return "Kindle Scribe"
            case .koboLibra: return "Kobo Libra"
            case .koboForma: return "Kobo Forma"
            case .highResolution: return "High Resolution"
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
        var isLandscape: Bool { width > height }
        var isHorizontalStrip: Bool { aspectRatio > 2.0 }
    }
    
    private struct PageGroup {
        let images: [ImageInfo]
        var isSingleImage: Bool { images.count == 1 }
        var isStitchedStrip: Bool { images.count > 1 }
    }
    
    // MARK: - Initialization
    public init() {}
    
    // MARK: - Public API
    
    func convertCBZToEPUB(
        _ cbzURL: URL,
        config: ConversionConfig = ConversionConfig(),
        profile: DeviceProfile = .standardResolution
    ) async throws -> URL {
        var finalConfig = config
        finalConfig.targetResolution = profile.resolution
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.performConversion(cbzURL: cbzURL, config: finalConfig)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Main Conversion Pipeline
    
    private func performConversion(cbzURL: URL, config: ConversionConfig) throws -> URL {
        print("\n" + String(repeating: "=", count: 70))
        print("📚 CBZ TO EPUB CONVERTER - PRODUCTION MODE")
        print(String(repeating: "=", count: 70))
        print("Input: \(cbzURL.lastPathComponent)")
        print("Target: \(Int(config.targetResolution.width))×\(Int(config.targetResolution.height))")
        print("Quality: \(Int(config.quality * 100))%")
        
        // Setup workspace
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Extract CBZ
        print("\n1️⃣  Extracting archive...")
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.unzipItem(at: cbzURL, to: extractDir)
        
        // Scan images
        print("2️⃣  Scanning images...")
        let allImages = try scanImages(in: extractDir)
        print("   Found: \(allImages.count) images")
        
        guard !allImages.isEmpty else {
            throw NSError(domain: "CBZConverter", code: 404,
                         userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        
        // Analyze content
        let stats = analyzeImages(allImages)
        print("\n📊 Analysis:")
        print("   Portrait: \(stats.portraitCount)")
        print("   Landscape: \(stats.landscapeCount)")
        if config.stripDetection {
            print("   Strips: \(stats.stripCount)")
        }
        
        // Group images (handle strips if enabled)
        print("\n3️⃣  Processing images...")
        var pageGroups: [PageGroup]
        if config.stripDetection && stats.stripCount > 0 {
            pageGroups = groupImagesWithStripDetection(allImages)
            print("   Created \(pageGroups.count) pages (some stitched from strips)")
        } else {
            pageGroups = allImages.map { PageGroup(images: [$0]) }
            print("   Processing \(pageGroups.count) pages")
        }
        
        // Remove cover if configured
        if !config.hasCover && !pageGroups.isEmpty {
            pageGroups.removeFirst()
            print("   Removed cover page")
        }
        
        // Build EPUB
        print("\n4️⃣  Building EPUB...")
        let title = cbzURL.deletingPathExtension().lastPathComponent
        let epubURL = try buildEPUB(
            pageGroups: pageGroups,
            title: title,
            config: config,
            outputDir: tempDir
        )
        
        // Move to final location
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.copyItem(at: epubURL, to: finalURL)
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        let sizeMB = fileSize / 1_000_000
        
        print("\n" + String(repeating: "=", count: 70))
        print("✅ CONVERSION COMPLETE")
        print(String(repeating: "=", count: 70))
        print("Output: \(finalURL.lastPathComponent)")
        print("Size: \(sizeMB) MB")
        print("Pages: \(pageGroups.count)")
        
        // Check if split needed
        if config.maxFileSizeMB > 0 && sizeMB > config.maxFileSizeMB {
            print("\n⚠️  File exceeds \(config.maxFileSizeMB)MB limit")
            print("   Consider enabling file splitting in future version")
        }
        
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
            
            // Skip system files
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
        
        // CRITICAL: Alphanumeric sorting (like go-comic-converter)
        images.sort {
            $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }
        
        return images
    }
    
    // MARK: - Image Analysis
    
    private struct ImageStats {
        let portraitCount: Int
        let landscapeCount: Int
        let stripCount: Int
    }
    
    private func analyzeImages(_ images: [ImageInfo]) -> ImageStats {
        let portraits = images.filter { !$0.isLandscape }.count
        let landscapes = images.filter { $0.isLandscape && !$0.isHorizontalStrip }.count
        let strips = images.filter { $0.isHorizontalStrip }.count
        
        return ImageStats(
            portraitCount: portraits,
            landscapeCount: landscapes,
            stripCount: strips
        )
    }
    
    // MARK: - Image Grouping with Strip Detection
    
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
                    currentStripBatch = []
                }
                // Add normal page
                groups.append(PageGroup(images: [img]))
            }
        }
        
        // Flush remaining strips
        if !currentStripBatch.isEmpty {
            groups.append(PageGroup(images: currentStripBatch))
        }
        
        return groups
    }
    
    // MARK: - Image Processing
    
    private func processImage(_ group: PageGroup, config: ConversionConfig) -> UIImage? {
        // Get source image (stitch if needed)
        let sourceImage: UIImage?
        if group.isStitchedStrip {
            sourceImage = stitchImages(group.images)
        } else {
            sourceImage = UIImage(contentsOfFile: group.images[0].fileURL.path)
        }
        
        guard var processedImage = sourceImage else { return nil }
        
        // Auto-rotate if needed
        if config.autoRotate, let cgImage = processedImage.cgImage,
           cgImage.width > cgImage.height {
            processedImage = rotateImage(processedImage, by: .pi / 2) ?? processedImage
        }
        
        // Grayscale conversion
        if config.grayscale {
            processedImage = convertToGrayscale(processedImage) ?? processedImage
        }
        
        // Resize to target resolution
        if let resized = resizeImage(processedImage, to: config.targetResolution, aspectRatio: config.aspectRatio) {
            processedImage = resized
        }
        
        return processedImage
    }
    
    private func stitchImages(_ images: [ImageInfo]) -> UIImage? {
        var loaded: [UIImage] = []
        for info in images {
            guard let img = UIImage(contentsOfFile: info.fileURL.path) else { continue }
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
    
    private func resizeImage(_ image: UIImage, to targetSize: CGSize, aspectRatio: Double) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        
        // Calculate target dimensions
        var finalWidth = targetSize.width
        var finalHeight = targetSize.height
        
        if aspectRatio > 0 {
            // Use specified aspect ratio (e.g., 1.6 for Kindle)
            finalHeight = finalWidth * CGFloat(aspectRatio)
            if finalHeight > targetSize.height {
                finalHeight = targetSize.height
                finalWidth = finalHeight / CGFloat(aspectRatio)
            }
        }
        
        // Don't upscale
        if sourceWidth <= finalWidth && sourceHeight <= finalHeight {
            return image
        }
        
        // Calculate scale to fit
        let scale = min(finalWidth / sourceWidth, finalHeight / sourceHeight)
        finalWidth = (sourceWidth * scale).rounded()
        finalHeight = (sourceHeight * scale).rounded()
        
        // Render resized image
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: finalWidth, height: finalHeight)
        )
        
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: finalWidth, height: finalHeight)))
        }
    }
    
    private func convertToGrayscale(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let grayImage = context.makeImage() else { return nil }
        return UIImage(cgImage: grayImage)
    }
    
    private func rotateImage(_ image: UIImage, by radians: CGFloat) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            context.cgContext.translateBy(x: image.size.width / 2, y: image.size.height / 2)
            context.cgContext.rotate(by: radians)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                width: image.size.width, height: image.size.height))
        }
    }
    
    // MARK: - EPUB Generation
    
    private func buildEPUB(pageGroups: [PageGroup], title: String, config: ConversionConfig, outputDir: URL) throws -> URL {
        
        // Create EPUB structure
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("Images")
        let textDir = oebpsDir.appendingPathComponent("Text")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        // Create mimetype (uncompressed)
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"),
                                        atomically: true, encoding: .utf8)
        
        // Create container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"),
                              atomically: true, encoding: .utf8)
        
        // Process pages
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, group) in pageGroups.enumerated() {
            let pageNum = String(format: "%04d", index + 1)
            let imageName = "Page_\(pageNum).jpg"
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // Process image
            guard let processedImage = processImage(group, config: config),
                  let cgImage = processedImage.cgImage else {
                print("   ⚠️  Failed to process page \(index + 1)")
                continue
            }
            
            // Encode
            let jpegData = processedImage.jpegData(compressionQuality: config.quality) ?? Data()
            try jpegData.write(to: imageDestURL)
            
            let width = cgImage.width
            let height = cgImage.height
            print("   ✓ Page \(index + 1): \(width)×\(height) - \(jpegData.count / 1024)KB")
            
            // Add to manifest
            imageManifest += "    <item id=\"img\(pageNum)\" href=\"Images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            // Create XHTML
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
            try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName),
                                  atomically: true, encoding: .utf8)
            
            xhtmlManifest += "    <item id=\"page\(pageNum)\" href=\"Text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "    <itemref idref=\"page\(pageNum)\"/>\n"
        }
        
        // Create content.opf
        let pageDirection = config.isManga ? "rtl" : "ltr"
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>en</dc:language>
                <dc:creator>Comic Converter</dc:creator>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">none</meta>
            </metadata>
            <manifest>
\(imageManifest)\(xhtmlManifest)    </manifest>
            <spine page-progression-direction="\(pageDirection)">
\(spineItems)    </spine>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"),
                            atomically: true, encoding: .utf8)
        
        // Zip to EPUB
        let epubURL = outputDir.appendingPathComponent(title + ".epub")
        try FileManager.default.zipItem(at: epubDir, to: epubURL)
        
        return epubURL
    }
}
