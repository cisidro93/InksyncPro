import UIKit
import ZIPFoundation
import PDFKit

class EPUBConverter {
    
    func convertEPUBToPDF(epubURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                // Extract EPUB
                try FileManager.default.unzipItem(at: epubURL, to: tempDir)
                
                // Get FULL pages (not slices)
                let pages = try self.extractFullPages(from: tempDir)
                
                if pages.isEmpty {
                    throw EPUBError.noImages
                }
                
                // Create PDF from complete pages
                let pdfURL = try self.createPDFFromPages(pages, outputDir: tempDir)
                
                DispatchQueue.main.async {
                    completion(.success(pdfURL))
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Fixed Page Extraction
    
    private func extractFullPages(from directory: URL) throws -> [UIImage] {
        // Strategy 1: Look for XHTML/HTML files that contain full page images
        if let htmlPages = try? extractPagesFromHTML(directory) {
            if !htmlPages.isEmpty {
                return htmlPages
            }
        }
        
        // Strategy 2: Find the largest images (these are usually full pages, not tiles)
        let images = try findLargestImages(in: directory)
        
        // Strategy 3: If we got sliced images, try to reconstruct them
        if images.isEmpty || self.appearsToBeTiled(images) {
            return try reconstructTiledPages(from: directory)
        }
        
        return images
    }
    
    private func extractPagesFromHTML(_ directory: URL) throws -> [UIImage] {
        var pages: [UIImage] = []
        let opfDir = try findContentDirectory(in: directory)
        
        // Find all XHTML/HTML files in reading order
        let htmlFiles = try findHTMLFilesInOrder(from: directory)
        
        for htmlURL in htmlFiles {
            // Parse HTML to find the main image reference
            if let imagePath = extractImagePathFromHTML(htmlURL) {
                let imageURL = opfDir.appendingPathComponent(imagePath)
                if let image = UIImage(contentsOfFile: imageURL.path) {
                    pages.append(image)
                }
            }
        }
        
        return pages
    }
    
    private func extractImagePathFromHTML(_ htmlURL: URL) -> String? {
        guard let htmlContent = try? String(contentsOf: htmlURL, encoding: .utf8) else {
            return nil
        }
        
        // Look for img src in the HTML
        // Pattern: <img src="images/page001.jpg" or "../images/page001.jpg"
        let patterns = [
            #"<img[^>]+src="([^"]+)""#,
            #"<image[^>]+xlink:href="([^"]+)""#,
            #"url\(([^)]+)\)"# // CSS background images
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: htmlContent, range: NSRange(htmlContent.startIndex..., in: htmlContent)) {
                if let range = Range(match.range(at: 1), in: htmlContent) {
                    return String(htmlContent[range])
                }
            }
        }
        
        return nil
    }
    
    private func findLargestImages(in directory: URL) throws -> [UIImage] {
        var imageFiles: [(url: URL, size: Int)] = []
        
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let fileSize = attrs[.size] as? Int {
                    imageFiles.append((url: fileURL, size: fileSize))
                }
            }
        }
        
        // Sort by file size (largest first) - full pages are usually bigger than tiles
        imageFiles.sort { $0.size > $1.size }
        
        // Filter: Only keep images above a certain size threshold (e.g., 50KB)
        let threshold = 50_000 // 50KB
        let largeImages = imageFiles.filter { $0.size > threshold }
        
        // Sort by filename for correct order
        let sortedByName = largeImages.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        
        var images: [UIImage] = []
        for item in sortedByName {
            if let image = UIImage(contentsOfFile: item.url.path) {
                // Additional check: skip images that are too narrow (likely tiles)
                if image.size.width > 300 { // Reasonable minimum page width
                    images.append(image)
                }
            }
        }
        
        return images
    }
    
    private func appearsToBeTiled(_ images: [UIImage]) -> Bool {
        // Check if images look like vertical slices
        guard let firstImage = images.first else { return false }
        
        let aspectRatio = firstImage.size.width / firstImage.size.height
        
        // If width is much smaller than height, it's probably a vertical slice
        return aspectRatio < 0.3
    }
    
    private func reconstructTiledPages(from directory: URL) throws -> [UIImage] {
        // Group images by page number (assuming naming like page1_slice1.jpg, page1_slice2.jpg)
        let allImages = try getAllImages(from: directory)
        let groupedPages = self.groupImagesByPage(allImages)
        
        var reconstructedPages: [UIImage] = []
        
        for (_, slices) in groupedPages.sorted(by: { $0.key < $1.key }) {
            if let stitchedPage = self.stitchVerticalSlices(slices) {
                reconstructedPages.append(stitchedPage)
            }
        }
        
        return reconstructedPages
    }
    
    private func getAllImages(from directory: URL) throws -> [(url: URL, image: UIImage)] {
        var images: [(url: URL, image: UIImage)] = []
        
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png"].contains(ext),
               let image = UIImage(contentsOfFile: fileURL.path) {
                images.append((url: fileURL, image: image))
            }
        }
        
        return images.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
    
    private func groupImagesByPage(_ images: [(url: URL, image: UIImage)]) -> [String: [UIImage]] {
        var groups: [String: [UIImage]] = [:]
        
        for (url, image) in images {
            // Extract page number from filename
            let filename = url.deletingPathExtension().lastPathComponent
            
            // Try to extract page identifier (everything before last underscore/dash)
            let components = filename.components(separatedBy: CharacterSet(charactersIn: "_-"))
            let pageKey = components.first ?? filename
            
            if groups[pageKey] == nil {
                groups[pageKey] = []
            }
            groups[pageKey]?.append(image)
        }
        
        return groups
    }
    
    private func stitchVerticalSlices(_ slices: [UIImage]) -> UIImage? {
        guard !slices.isEmpty else { return nil }
        
        // Calculate total height and max width
        let totalHeight = slices.reduce(0) { $0 + $1.size.height }
        let maxWidth = slices.map { $0.size.width }.max() ?? 0
        
        let size = CGSize(width: maxWidth, height: totalHeight)
        
        // Use UIGraphicsImageRenderer with 1.0 scale and opaque background to prevent corruption
        // (Replaces legacy UIGraphicsBeginImageContextWithOptions)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        
        return renderer.image { context in
             var yOffset: CGFloat = 0
             for slice in slices {
                 slice.draw(at: CGPoint(x: 0, y: yOffset))
                 yOffset += slice.size.height
             }
        }
    }
    
    private func findContentDirectory(in directory: URL) throws -> URL {
        // Look for common EPUB content directories
        let commonDirs = ["OEBPS", "OPS", "content", ""]
        
        for dir in commonDirs {
            let testURL = directory.appendingPathComponent(dir)
            if FileManager.default.fileExists(atPath: testURL.path) {
                return testURL
            }
        }
        
        return directory
    }
    
    private func findHTMLFilesInOrder(from directory: URL) throws -> [URL] {
        var htmlFiles: [URL] = []
        
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ["xhtml", "html", "htm"].contains(ext) {
                htmlFiles.append(fileURL)
            }
        }
        
        // Sort by filename
        return htmlFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    private func createPDFFromPages(_ images: [UIImage], outputDir: URL) throws -> URL {
        let pdfURL = outputDir.appendingPathComponent("converted.pdf")
        
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

enum EPUBError: LocalizedError {
    case opfNotFound
    case invalidOPF
    case noImages
    case extractionFailed
    
    var errorDescription: String? {
        switch self {
        case .opfNotFound: return "Could not find EPUB content file"
        case .invalidOPF: return "EPUB file is corrupted"
        case .noImages: return "No images found in EPUB"
        case .extractionFailed: return "Failed to extract EPUB"
        }
    }
}
