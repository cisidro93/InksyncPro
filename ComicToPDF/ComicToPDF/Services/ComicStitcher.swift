import UIKit
import ImageIO

// Model to represent a final page (which may consist of 1 or multiple source images)
struct ComicPageModel {
    let id: UUID = UUID()
    let images: [URL]
    
    var isComposite: Bool {
        return images.count > 1
    }
}

/// Analysis engine that groups raw image files into logical pages
class ComicStitcher {
    
    /// Analyzes a list of image URLs and groups webtoon/manga strips into single pages.
    /// - Parameter imageURLs: Sorted list of file URLs from the decompressed CBZ.
    /// - Returns: An array of ComicPageModel, where each model represents one final EPUB page.
    static func analyzeAndGroup(imageURLs: [URL]) -> [ComicPageModel] {
        var pages: [ComicPageModel] = []
        var currentStrips: [URL] = []
        
        // Configuration constants
        let stripAspectRatioThreshold: CGFloat = 2.0 // Width > 2x Height implies a horizontal strip
        
        for url in imageURLs {
            // Efficiently check dimensions without loading the full image into memory
            guard let size = getImageSize(url: url) else {
                // If we can't read it, treat as a standalone page to be safe
                if !currentStrips.isEmpty {
                    pages.append(ComicPageModel(images: currentStrips))
                    currentStrips.removeAll()
                }
                pages.append(ComicPageModel(images: [url]))
                continue
            }
            
            let aspectRatio = size.width / size.height
            
            if aspectRatio > stripAspectRatioThreshold {
                // It is a strip; add to current batch
                currentStrips.append(url)
            } else {
                // It is a full page
                
                // 1. Flush any pending strips as a combined page
                if !currentStrips.isEmpty {
                    pages.append(ComicPageModel(images: currentStrips))
                    currentStrips.removeAll()
                }
                
                // 2. Add this full page
                pages.append(ComicPageModel(images: [url]))
            }
        }
        
        // Flush remaining strips
        if !currentStrips.isEmpty {
            pages.append(ComicPageModel(images: currentStrips))
        }
        
        return pages
    }
    
    /// Helper: Get dimensions using ImageIO (Low Memory Footprint)
    private static func getImageSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [NSString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
    
    /// Helper: Stitch images vertically into a single UIImage
    static func stitchImagesVertically(_ images: [UIImage]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        if images.count == 1 { return images.first }
        
        let width = images[0].size.width
        let totalHeight = images.reduce(0) { $0 + $1.size.height }
        let scale = images[0].scale
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: totalHeight), format: format)
        
        return renderer.image { context in
            var yOffset: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: yOffset))
                yOffset += image.size.height
            }
        }
    }
}
