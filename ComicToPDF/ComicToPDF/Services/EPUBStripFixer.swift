import UIKit
import ZIPFoundation

class EPUBStripFixer {
    
    // MANUAL CONTROL VERSION - you specify strips per page
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
                    print("  ✓ Loaded: \(fileURL.lastPathComponent) - \(Int(img.size.width))x\(Int(img.size.height))")
                }
            }
            
            // 4. Combine strips into pages
            var fullPages: [UIImage] = []
            let pageCount = strips.count / stripsPerPage
            
            for pageNum in 0..<pageCount {
                let start = pageNum * stripsPerPage
                let end = start + stripsPerPage
                let pageStrips = Array(strips[start..<end])
                
                if let combinedPage = Self.combineStripsVertically(pageStrips) {
                    fullPages.append(combinedPage)
                    print("✂️ Created page \(pageNum + 1) from \(pageStrips.count) strips")
                }
            }
            
            print("📄 Created \(fullPages.count) complete pages")
            
            // 5. Make PDF
            let pdfURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(epubURL.deletingPathExtension().lastPathComponent + "_FIXED.pdf")
            
            try self.makePDF(from: fullPages, outputURL: pdfURL)
            print("✅ PDF saved: \(pdfURL.lastPathComponent)")
            
            return pdfURL
            
        } catch {
            print("❌ Error: \(error)")
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
    
    static func combineStripsVertically(_ strips: [UIImage]) -> UIImage? {
        guard !strips.isEmpty else { return nil }
        
        // Calculate total size
        let width = strips[0].size.width
        let height = strips.reduce(CGFloat(0)) { $0 + $1.size.height }
        
        // Fix: Use UIGraphicsImageRenderer to avoid Retina scaling artifacts (stripes)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        
        return renderer.image { context in
            var y: CGFloat = 0
            for strip in strips {
                strip.draw(at: CGPoint(x: 0, y: y))
                y += strip.size.height
            }
        }
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
