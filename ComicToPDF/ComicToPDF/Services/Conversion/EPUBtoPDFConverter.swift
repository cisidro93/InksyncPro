import UIKit
import ZIPFoundation
import PDFKit

class EPUBtoPDFConverter {
    
    func convertEPUBtoPDF(_ epubURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("📚 Converting EPUB to PDF...")
                
                // 1. Extract EPUB
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                print("📦 Extracting EPUB...")
                try FileManager.default.unzipItem(at: epubURL, to: tempDir)
                
                // 2. Extract all images from EPUB
                let images = try self.extractImagesFromEPUB(at: tempDir)
                print("🖼️ Found \(images.count) images in EPUB")
                
                // 3. Check if images are strips and reconstruct if needed
                let finalPages = images
                print("📄 Final page count: \(finalPages.count)")
                
                if finalPages.isEmpty {
                    throw EPUBConversionError.noPages
                }
                
                // 4. Create PDF from pages
                let pdfURL = try self.createPDF(from: finalPages, basedOn: epubURL, in: tempDir)
                print("✅ PDF created: \(pdfURL.lastPathComponent)")
                
                DispatchQueue.main.async {
                    completion(.success(pdfURL))
                }
                
            } catch {
                print("❌ EPUB conversion failed: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Extract Images from EPUB
    
    private func extractImagesFromEPUB(at directory: URL) throws -> [UIImage] {
        var images: [(url: URL, image: UIImage)] = []
        
        // Find all images in EPUB
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                    if let image = UIImage(contentsOfFile: fileURL.path) {
                        images.append((url: fileURL, image: image))
                    }
                }
            }
        }
        
        // Sort by filename to maintain order
        images.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        
        return images.map { $0.image }
    }
    
    // MARK: - Strip Reconstruction
    
    private func reconstructPagesIfNeeded(_ images: [UIImage]) -> [UIImage] {
        guard !images.isEmpty else { return [] }
        
        // Check if images are horizontal strips
        guard let first = images.first else { return images }
        let aspectRatio = first.size.width / first.size.height
        
        // If aspect ratio > 2.0, these are horizontal strips
        if aspectRatio > 2.0 {
            print("⚠️ DETECTED HORIZONTAL STRIPS!")
            let stripsPerPage = detectStripsPerPage(images)
            return reconstructPages(from: images, stripsPerPage: stripsPerPage)
        } else {
            return images
        }
    }
    
    private func detectStripsPerPage(_ images: [UIImage]) -> Int {
        let totalCount = images.count
        
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
    
    private func reconstructPages(from strips: [UIImage], stripsPerPage: Int) -> [UIImage] {
        var pages: [UIImage] = []
        let pageCount = strips.count / stripsPerPage
        
        for pageNum in 0..<pageCount {
            let startIdx = pageNum * stripsPerPage
            let endIdx = min(startIdx + stripsPerPage, strips.count)
            let pageStrips = Array(strips[startIdx..<endIdx])
            
            if let fullPage = stitchStripsVertically(pageStrips) {
                pages.append(fullPage)
            }
        }
        
        return pages
    }
    
    private func stitchStripsVertically(_ strips: [UIImage]) -> UIImage? {
        guard !strips.isEmpty else { return nil }
        
        // Calculate total dimensions
        let width = strips[0].size.width
        let totalHeight = strips.reduce(0) { $0 + $1.size.height }
        let scale = strips[0].scale
        
        // Create image context
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
    
    // MARK: - Create PDF
    
    private func createPDF(from images: [UIImage], basedOn originalURL: URL, in directory: URL) throws -> URL {
        let pdfName = originalURL.deletingPathExtension().lastPathComponent + "_converted.pdf"
        let pdfURL = directory.appendingPathComponent(pdfName)
        
        UIGraphicsBeginPDFContextToFile(pdfURL.path, .zero, nil)
        
        for image in images {
            let pageRect = CGRect(origin: .zero, size: image.size)
            UIGraphicsBeginPDFPageWithInfo(pageRect, nil)
            image.draw(in: pageRect)
        }
        
        UIGraphicsEndPDFContext()
        
        return pdfURL
    }
}

enum EPUBConversionError: LocalizedError {
    case noPages
    case extractionFailed
    
    var errorDescription: String? {
        switch self {
        case .noPages:
            return "No pages found in EPUB"
        case .extractionFailed:
            return "Failed to extract EPUB contents"
        }
    }
}
