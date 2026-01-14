import UIKit
import ZIPFoundation
import Accelerate

class EPUBStripFixer {
    
    // MARK: - Shared Logic (Copied from EPUBtoPDFConverter)
    
    static func detectStripsPerPage(_ totalCount: Int) -> Int {
        // Try common strip counts
        for strips in [10, 8, 7, 6, 5, 4] {
            if totalCount % strips == 0 {
                return strips
            }
        }
        
        // Fallback: check if 32 pages with common strip patterns
        if totalCount == 32 {
            return 8
        }
        
        return 6 // Default fallback
    }
    
    static func reconstructPages(from strips: [UIImage], stripsPerPage: Int) -> [UIImage] {
        var pages: [UIImage] = []
        let pageCount = strips.count / stripsPerPage
        
        for pageNum in 0..<pageCount {
            let startIdx = pageNum * stripsPerPage
            let endIdx = min(startIdx + stripsPerPage, strips.count)
            let pageStrips = Array(strips[startIdx..<endIdx])
            
            if let fullPage = combineStripsVertically(pageStrips) {
                pages.append(fullPage)
            }
        }
        
        return pages
    }
    
    static func combineStripsVertically(_ strips: [UIImage]) -> UIImage? {
        guard !strips.isEmpty else { return nil }
        
        // Optimize: Use vDSP for vectorized summation of heights
        // This is significantly faster for large arrays than high-level reduce
        let heights = strips.map { Float($0.size.height) }
        let totalHeight = CGFloat(vDSP.sum(heights))
        
        let width = strips[0].size.width
        let scale = strips[0].scale
        
        // Optimize: Use CoreGraphics CGBitmapContext directly
        // This avoids the overhead of UIGraphicsBeginImageContext stack
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: Int(width * scale),
            height: Int(totalHeight * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        
        // Draw strips vertically
        var currentY: CGFloat = 0
        
        // Flip context for "User Space" coordinates (Core Graphics is bottom-up)
        // However, since we are drawing images which are also flipped, standard draw usually works if we don't flip.
        // But for CGBitmapContext without UIKit shim, y=0 is bottom.
        // We need to draw from Top to Bottom physically.
        
        for strip in strips {
            guard let cgImage = strip.cgImage else { continue }
            let h = CGFloat(cgImage.height) // Physical pixels
            let w = CGFloat(cgImage.width)
            
            // In CG coords (0,0 is bottom-left), so "Top" is at y = TotalHeight - h
            // We want to draw the first strip at the TOP.
            // First strip y = (TotalHeight * scale) - h
            
            // Adjust logic:
            // currentY starts at TotalHeight (Top)
            // subtract strip height to get origin.y
            
            // Wait, simpler approach: Flip the CTM so it matches UIKit (0,0 top-left)
            // context.translateBy(x: 0, y: height)
            // context.scaleBy(x: 1.0, y: -1.0)
            
            // Let's do the manual calculation to be safe and "Accelerated"
            // Destination Y for top of image (in standard coord system)
            
             // Draw rect in native pixels
            let drawRect = CGRect(x: 0, y: CGFloat(Int(totalHeight * scale)) - currentY - h, width: w, height: h)
            context.draw(cgImage, in: drawRect)
            
            currentY += h
        }
        
        guard let resultCG = context.makeImage() else { return nil }
        return UIImage(cgImage: resultCG, scale: scale, orientation: .up)
    }
    
    // MARK: - Original Instance Methods (Refactored to use static logic)
    
    func fixEPUBStrips(_ epubURL: URL, stripsPerPage: Int = 6) -> URL? {
        print("🔧 Starting EPUB strip repair...")
        print("📋 Will combine \(stripsPerPage) strips into each page")
        
        do {
            // 1. Extract EPUB
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: epubURL, to: tempDir)
            print("✅ Extracted EPUB")
            
            // 2. Get ALL images in order
            let imageFiles = try self.getOrderedImages(from: tempDir)
            print("📸 Found \(imageFiles.count) image files")
            
            // 3. Load images
            var strips: [UIImage] = []
            for fileURL in imageFiles {
                if let img = UIImage(contentsOfFile: fileURL.path) {
                    strips.append(img)
                }
            }
            
            // 4. Reconstruct Pages
            let pages = Self.reconstructPages(from: strips, stripsPerPage: stripsPerPage)
            print("📄 Reconstructed \(pages.count) pages")
            
            // 5. Create PDF
            let pdfName = epubURL.deletingPathExtension().lastPathComponent + "_fixed.pdf"
            let outputURL = epubURL.deletingLastPathComponent().appendingPathComponent(pdfName)
            
            try self.makePDF(from: pages, outputURL: outputURL)
            print("✅ Created fixed PDF: \(outputURL.path)")
            
            try FileManager.default.removeItem(at: tempDir)
            return outputURL
            
        } catch {
            print("❌ Failed to fix strips: \(error)")
            return nil
        }
    }
    
    private func getOrderedImages(from directory: URL) throws -> [URL] {
        var imageURLs: [URL] = []
        
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if ["jpg", "jpeg", "png", "gif"].contains(fileURL.pathExtension.lowercased()) {
                    imageURLs.append(fileURL)
                }
            }
        }
        
        // Sort alphabetically
        return imageURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    private func makePDF(from images: [UIImage], outputURL: URL) throws {
        UIGraphicsBeginPDFContextToFile(outputURL.path, .zero, nil)
        
        for image in images {
            let rect = CGRect(origin: .zero, size: image.size)
            UIGraphicsBeginPDFPageWithInfo(rect, nil)
            image.draw(in: rect)
        }
        
        UIGraphicsEndPDFContext()
    }
}
