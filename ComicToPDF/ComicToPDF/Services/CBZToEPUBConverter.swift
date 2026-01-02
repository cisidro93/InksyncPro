// ============================================================================
// COMPLETE CBZ TO EPUB CONVERTER WITH DIAGNOSTIC LOGGING
// ============================================================================
// 
// PURPOSE: Fix the "horizontal snipping" issue where manga pages appear as
//          12-13 repeated horizontal strips in the converted EPUB
//
// THIS FILE CONTAINS:
// 1. Full diagnostic logging to show exactly what's in your CBZ
// 2. Smart strip detection and stitching
// 3. Quality-based resolution handling
// 4. Complete EPUB generation with proper metadata
//
// USAGE IN ANTIGRAVITY IDE:
// 1. Paste this ENTIRE file into Antigravity
// 2. Tell it to "Replace the CBZToEPUBConverter.swift file with this code"
// 3. Run a conversion to see diagnostic output
// 4. The console will show EXACTLY what's happening to your images
//
// ============================================================================

import Foundation
import UIKit
import ZIPFoundation

// MARK: - CBZToEPUBConverter - COMPLETE WITH DIAGNOSTICS

class CBZToEPUBConverter {
    
    private let stripAspectRatioThreshold: Double = 2.0
    
    // MARK: - Initialization
    public init() {}
    
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
    
    // MARK: - Main Conversion Pipeline
    
    private func performConversion(cbzURL: URL, compressionQuality: Double) throws -> URL {
        print("\n" + String(repeating: "=", count: 80))
        print("🚀 STARTING CBZ TO EPUB CONVERSION (DIAGNOSTIC MODE)")
        print(String(repeating: "=", count: 80))
        print("Source: \(cbzURL.lastPathComponent)")
        print("Compression: \(Int(compressionQuality * 100))%")
        
        // Setup temporary workspace
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        print("\n📦 Extracting CBZ...")
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.unzipItem(at: cbzURL, to: extractDir)
        print("✅ Extracted to temporary directory")
        
        // Scan images with DETAILED logging
        print("\n📸 Scanning for images...")
        let allImages = try scanAndListAllImages(in: extractDir)
        
        guard !allImages.isEmpty else {
            throw NSError(domain: "CBZConverter", code: 404, 
                         userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ"])
        }
        
        print("\n" + String(repeating: "-", count: 80))
        print("📊 COMPLETE FILE LIST (in order they'll be processed):")
        print(String(repeating: "-", count: 80))
        
        for (index, img) in allImages.enumerated() {
            let ar = String(format: "%.2f", img.aspectRatio)
            let typeIcon = img.aspectRatio > stripAspectRatioThreshold ? "🔹" : "📄"
            let typeName = img.aspectRatio > stripAspectRatioThreshold ? "STRIP" : "PAGE"
            print(String(format: "[%3d] %s %-40s %4d×%-4d AR:%-5s %s",
                        index + 1,
                        typeIcon,
                        String(img.filename.prefix(40)),
                        img.width,
                        img.height,
                        ar,
                        typeName))
        }
        
        // Analyze and group
        print("\n🔍 Analyzing layout...")
        let stripCount = allImages.filter { $0.aspectRatio > stripAspectRatioThreshold }.count
        print("   • Portrait pages: \(allImages.count - stripCount)")
        print("   • Horizontal strips: \(stripCount)")
        
        if stripCount > 0 {
            print("   ⚠️  STRIPS DETECTED - Stitching will be applied")
        } else {
            print("   ✓ No strips - All pages are normal portrait")
        }
        
        // Group images
        let pageGroups = groupImages(allImages)
        
        print("\n📦 Grouped into \(pageGroups.count) final pages:")
        for (index, group) in pageGroups.enumerated() {
            if group.images.count > 1 {
                let height = group.images.reduce(0) { $0 + $1.height }
                print("   [Page \(index + 1)] STITCHED from \(group.images.count) strips → \(group.images[0].width)×\(height)px")
            } else {
                print("   [Page \(index + 1)] \(group.images[0].filename) → \(group.images[0].width)×\(group.images[0].height)px")
            }
        }
        
        // Build EPUB
        print("\n📚 Building EPUB structure...")
        let title = cbzURL.deletingPathExtension().lastPathComponent
        let epubURL = try buildEPUB(
            pageGroups: pageGroups,
            title: title,
            outputDir: tempDir,
            compressionQuality: compressionQuality
        )
        
        // Move to persistent location
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.copyItem(at: epubURL, to: finalURL)
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        
        print("\n" + String(repeating: "=", count: 80))
        print("✅ CONVERSION COMPLETE")
        print(String(repeating: "=", count: 80))
        print("Output: \(finalURL.lastPathComponent)")
        print("Size: \(fileSize / 1_000_000) MB")
        print("Pages: \(pageGroups.count)")
        
        return finalURL
    }
    
    // MARK: - Image Scanning with Full Details
    
    struct ImageInfo {
        let fileURL: URL
        let filename: String
        let width: Int
        let height: Int
        var aspectRatio: Double { Double(width) / Double(height) }
    }
    
    struct PageGroup {
        let images: [ImageInfo]
        var isSinglePage: Bool { images.count == 1 }
    }
    
    private func scanAndListAllImages(in directory: URL) throws -> [ImageInfo] {
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
            
            // Skip metadata files
            if fileURL.lastPathComponent.hasPrefix(".") ||
               fileURL.lastPathComponent.hasPrefix("__") ||
               fileURL.path.contains("__MACOSX") {
                continue
            }
            
            guard supportedExtensions.contains(ext) else { continue }
            
            // Load and measure image - USING CORRECT METHOD (not broken Apple API)
            guard let image = UIImage(contentsOfFile: fileURL.path),
                  let cgImage = image.cgImage else {
                print("   ⚠️ Skipping unreadable file: \(fileURL.lastPathComponent)")
                continue
            }
            
            images.append(ImageInfo(
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                width: cgImage.width,
                height: cgImage.height
            ))
        }
        
        // CRITICAL: Sort alphanumerically to ensure correct page order
        images.sort { 
            $0.filename.localizedStandardCompare($1.filename) == .orderedAscending 
        }
        
        return images
    }
    
    // MARK: - Smart Grouping Logic
    
    private func groupImages(_ images: [ImageInfo]) -> [PageGroup] {
        var groups: [PageGroup] = []
        var currentStripBatch: [ImageInfo] = []
        
        for img in images {
            let isStrip = img.aspectRatio > stripAspectRatioThreshold
            
            if isStrip {
                // It's a strip - add to current batch
                currentStripBatch.append(img)
            } else {
                // It's a normal page
                // First, flush any pending strips
                if !currentStripBatch.isEmpty {
                    groups.append(PageGroup(images: currentStripBatch))
                    currentStripBatch = []
                }
                // Add this normal page
                groups.append(PageGroup(images: [img]))
            }
        }
        
        // Flush remaining strips
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
        
        print("      🧵 Stitching \(images.count) images...")
        
        // Load all images
        var loaded: [UIImage] = []
        for img in images {
            guard let uiImage = UIImage(contentsOfFile: img.fileURL.path) else {
                print("      ⚠️ Failed to load: \(img.filename)")
                continue
            }
            loaded.append(uiImage)
        }
        
        guard !loaded.isEmpty else { return nil }
        
        // Calculate dimensions
        let width = loaded[0].size.width
        let totalHeight = loaded.reduce(0) { $0 + $1.size.height }
        let scale = loaded[0].scale
        
        print("      📐 Stitching to: \(Int(width))×\(Int(totalHeight))")
        
        // Create stitched image using UIGraphicsImageContext (PROVEN METHOD)
        UIGraphicsBeginImageContextWithOptions(
            CGSize(width: width, height: totalHeight),
            false,
            scale
        )
        defer { UIGraphicsEndImageContext() }
        
        var yOffset: CGFloat = 0
        for (index, img) in loaded.enumerated() {
            img.draw(at: CGPoint(x: 0, y: yOffset))
            print("      ✏️  Strip \(index + 1) drawn at y=\(Int(yOffset))")
            yOffset += img.size.height
        }
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        if let result = result {
            print("      ✅ Stitched successfully: \(Int(result.size.width))×\(Int(result.size.height))")
        }
        return result
    }
    
    // MARK: - EPUB Building
    
    private func buildEPUB(pageGroups: [PageGroup], title: String, outputDir: URL, compressionQuality: Double) throws -> URL {
        
        // Create EPUB structure
        let epubDir = outputDir.appendingPathComponent("epub_build")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        
        // Create mimetype (MUST be uncompressed)
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        
        // Create container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // Process pages
        var imageManifest = ""
        var xhtmlManifest = ""
        var spineItems = ""
        
        for (index, group) in pageGroups.enumerated() {
            print("\n   📄 Processing page \(index + 1)/\(pageGroups.count)...")
            
            let pageNum = String(format: "%04d", index + 1)
            let imageName = "page\(pageNum).jpg"
            let imageDestURL = imagesDir.appendingPathComponent(imageName)
            
            // Get final image (stitch if needed)
            let finalImage: UIImage?
            if group.isSinglePage {
                finalImage = UIImage(contentsOfFile: group.images[0].fileURL.path)
                print("      📖 Single image: \(group.images[0].width)×\(group.images[0].height)")
            } else {
                finalImage = stitchImages(group.images)
                let totalHeight = group.images.reduce(0) { $0 + $1.height }
                print("      ✂️  Stitched \(group.images.count) strips: \(group.images[0].width)×\(totalHeight)")
            }
            
            guard let sourceImage = finalImage,
                  let cgImage = sourceImage.cgImage else {
                print("      ❌ Failed to process page \(index + 1)")
                continue
            }
            
            // Smart resizing based on quality
            let sourceWidth = CGFloat(cgImage.width)
            let sourceHeight = CGFloat(cgImage.height)
            
            // Quality-based max dimension (higher quality = larger images)
            let maxDimension: CGFloat = compressionQuality >= 0.9 ? 4096 : 
                                       compressionQuality >= 0.8 ? 3200 : 2560
            
            var targetWidth = sourceWidth
            var targetHeight = sourceHeight
            
            if sourceWidth > maxDimension || sourceHeight > maxDimension {
                let scale = min(maxDimension / sourceWidth, maxDimension / sourceHeight, 1.0)
                targetWidth = (sourceWidth * scale).rounded()
                targetHeight = (sourceHeight * scale).rounded()
                print("      ⬇️  Resizing to \(Int(targetWidth))×\(Int(targetHeight))")
            } else {
                print("      ✓ Keeping original size")
            }
            
            // Encode to JPEG
            let imageToEncode: UIImage
            if targetWidth != sourceWidth || targetHeight != sourceHeight {
                // Need to resize
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: targetHeight))
                imageToEncode = renderer.image { _ in
                    sourceImage.draw(in: CGRect(origin: .zero, size: CGSize(width: targetWidth, height: targetHeight)))
                }
            } else {
                imageToEncode = sourceImage
            }
            
            guard let jpegData = imageToEncode.jpegData(compressionQuality: compressionQuality) else {
                print("      ❌ Failed to encode JPEG")
                continue
            }
            
            try jpegData.write(to: imageDestURL)
            print("      ✅ Saved: \(jpegData.count / 1024)KB at \(Int(compressionQuality * 100))% quality")
            
            // Add to manifest
            imageManifest += "    <item id=\"img_\(pageNum)\" href=\"images/\(imageName)\" media-type=\"image/jpeg\"/>\n"
            
            // Create XHTML
            let xhtmlContent = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>Page \(index + 1)</title>
                <meta name="viewport" content="width=\(Int(targetWidth)), height=\(Int(targetHeight))" />
            </head>
            <body style="margin:0;padding:0;">
                <img src="../images/\(imageName)" alt="Page \(index + 1)" style="width:100%;height:100%;object-fit:contain;"/>
            </body>
            </html>
            """
            
            let xhtmlName = "page\(pageNum).xhtml"
            try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)
            
            xhtmlManifest += "    <item id=\"page_\(pageNum)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "    <itemref idref=\"page_\(pageNum)\"/>\n"
        }
        
        // Create content.opf (EPUB metadata)
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>en</dc:language>
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
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // Zip to EPUB
        let epubURL = outputDir.appendingPathComponent(title + ".epub")
        try FileManager.default.zipItem(at: epubDir, to: epubURL)
        
        return epubURL
    }
}
