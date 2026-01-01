import UIKit
import ZIPFoundation

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
        
        // Calculate total dimensions
        let width = strips[0].size.width
        let totalHeight = strips.reduce(0) { $0 + $1.size.height }
        let scale = strips[0].scale
        
        // Use legacy context as it is confirmed to work well in conversions
        UIGraphicsBeginImageContextWithOptions(
            CGSize(width: width, height: totalHeight),
            false,
            scale
        )
        defer { UIGraphicsEndImageContext() }
        
        // Draw strips vertically
        var yOffset: CGFloat = 0
        for strip in strips {
            strip.draw(at: CGPoint(x: 0, y: yOffset))
            yOffset += strip.size.height
        }
        
        return UIGraphicsGetImageFromCurrentImageContext()
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
