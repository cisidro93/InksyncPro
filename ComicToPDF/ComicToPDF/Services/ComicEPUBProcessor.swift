// Complete EPUB to PDF Converter - Drop this entire file into your project

import UIKit
import ZIPFoundation

class ComicEPUBProcessor {
    
    static let shared = ComicEPUBProcessor()
    
    // Main conversion function - call this from your file picker
    func convertEPUBIfNeeded(_ fileURL: URL, completion: @escaping (URL?, Error?) -> Void) {
        
        // Check if it's an EPUB
        guard fileURL.pathExtension.lowercased() == "epub" else {
            completion(fileURL, nil) // Not an EPUB, return original
            return
        }
        
        print("🔄 Detected EPUB file, starting conversion...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let pdfURL = try self.processEPUB(fileURL)
                DispatchQueue.main.async {
                    print("✅ EPUB converted successfully to: \(pdfURL.lastPathComponent)")
                    completion(pdfURL, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ EPUB conversion failed: \(error)")
                    completion(nil, error)
                }
            }
        }
    }
    
    private func processEPUB(_ epubURL: URL) throws -> URL {
        // 1. Create temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        print("📂 Extracting EPUB to: \(tempDir.path)")
        
        // 2. Extract EPUB (it's a ZIP)
        try FileManager.default.unzipItem(at: epubURL, to: tempDir)
        
        // 3. Get all images
        let images = try getAllImages(from: tempDir)
        print("🖼️ Found \(images.count) images")
        
        // 4. Detect if they're strips
        let isStrips = detectIfStrips(images.map { $0.image })
        print("🔍 Images are \(isStrips ? "STRIPS - will reconstruct" : "FULL PAGES")")
        
        // 5. Reconstruct or use as-is
        let finalPages: [UIImage]
        if isStrips {
            finalPages = try reconstructPages(from: images)
            print("🔧 Reconstructed \(finalPages.count) full pages from strips")
        } else {
            finalPages = images.map { $0.image }
        }
        
        // 6. Create PDF
        let pdfName = epubURL.deletingPathExtension().lastPathComponent + "_converted.pdf"
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent(pdfName)
        try createPDF(from: finalPages, at: pdfURL)
        
        print("📄 Created PDF with \(finalPages.count) pages")
        
        return pdfURL
    }
    
    // Get all images from extracted EPUB
    private func getAllImages(from directory: URL) throws -> [(url: URL, image: UIImage)] {
        var results: [(url: URL, image: UIImage)] = []
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw EPUBError.extractionFailed
        }
        
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif"].contains(ext) {
                if let image = UIImage(contentsOfFile: fileURL.path) {
                    results.append((url: fileURL, image: image))
                }
            }
        }
        
        // Sort by filename
        results.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        
        return results
    }
    
    // Detect if images are horizontal strips
    private func detectIfStrips(_ images: [UIImage]) -> Bool {
        guard !images.isEmpty else { return false }
        
        // Check first few images
        let sampleSize = min(5, images.count)
        var stripCount = 0
        
        for i in 0..<sampleSize {
            let image = images[i]
            let aspectRatio = image.size.width / image.size.height
            
            // If width >> height, it's a strip (aspect > 2.0)
            if aspectRatio > 2.0 {
                stripCount += 1
            }
        }
        
        // If majority are strips, treat as strips
        return stripCount >= (sampleSize / 2)
    }
    
    // Reconstruct full pages from strips
    private func reconstructPages(from strips: [(url: URL, image: UIImage)]) throws -> [UIImage] {
        guard !strips.isEmpty else { return [] }
        
        // Determine strips per page
        let stripsPerPage = calculateStripsPerPage(strips.count)
        print("📐 Using \(stripsPerPage) strips per page")
        
        var pages: [UIImage] = []
        
        // Group and stitch
        for pageIndex in 0..<(strips.count / stripsPerPage) {
            let startIdx = pageIndex * stripsPerPage
            let endIdx = min(startIdx + stripsPerPage, strips.count)
            
            let pageStrips = Array(strips[startIdx..<endIdx]).map { $0.image }
            
            if let fullPage = stitchStrips(pageStrips) {
                pages.append(fullPage)
                print("✂️ Stitched page \(pageIndex + 1)")
            }
        }
        
        return pages
    }
    
    // Calculate how many strips make one page
    private func calculateStripsPerPage(_ totalCount: Int) -> Int {
        // Try common values: 10, 8, 6, 5, 4
        for strips in [10, 8, 6, 5, 4] {
            if totalCount % strips == 0 {
                return strips
            }
        }
        // Default to 6 if no clean division
        return 6
    }
    
    // Stitch horizontal strips vertically into one page
    private func stitchStrips(_ strips: [UIImage]) -> UIImage? {
        guard !strips.isEmpty else { return nil }
        
        let width = strips.first!.size.width
        let totalHeight = strips.reduce(0) { $0 + $1.size.height }
        
        // Fix: Use UIGraphicsImageRenderer to avoid Retina scaling artifacts (stripes)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: totalHeight), format: format)
        
        return renderer.image { context in
            var y: CGFloat = 0
            for strip in strips {
                strip.draw(at: CGPoint(x: 0, y: y))
                y += strip.size.height
            }
        }
    }
    
    // Create PDF from images
    private func createPDF(from images: [UIImage], at url: URL) throws {
        UIGraphicsBeginPDFContextToFile(url.path, .zero, nil)
        
        for image in images {
            let pageRect = CGRect(origin: .zero, size: image.size)
            UIGraphicsBeginPDFPageWithInfo(pageRect, nil)
            image.draw(in: pageRect)
        }
        
        UIGraphicsEndPDFContext()
    }
}

enum EPUBError: LocalizedError {
    case extractionFailed
    case noImages
    
    var errorDescription: String? {
        switch self {
        case .extractionFailed: return "Failed to extract EPUB archive"
        case .noImages: return "No images found in EPUB"
        }
    }
}
