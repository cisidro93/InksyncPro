import UIKit

struct ImageProcessor {
    
    /// Processes a single image. If it's a spread and splitting is enabled, returns two images.
    /// Otherwise returns the original image in an array.
    static func processPage(_ image: UIImage, splitSpreads: Bool, isManga: Bool) -> [UIImage] {
        
        // 1. If splitting is off, or image is nil, return original
        guard splitSpreads else { return [image] }
        
        // 2. Check Aspect Ratio (Is it Landscape?)
        // Standard comics are usually portrait. If Width > Height * 1.2, it's likely a spread.
        let isLandscape = image.size.width > (image.size.height * 1.2)
        
        if isLandscape {
            return splitSpread(image, isManga: isManga)
        } else {
            return [image]
        }
    }
    
    private static func splitSpread(_ image: UIImage, isManga: Bool) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let halfWidth = width / 2.0
        
        // Create Rects for Left and Right halves
        let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
        let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)
        
        guard let leftCG = cgImage.cropping(to: leftRect),
              let rightCG = cgImage.cropping(to: rightRect) else {
            return [image]
        }
        
        let leftPage = UIImage(cgImage: leftCG, scale: image.scale, orientation: image.imageOrientation)
        let rightPage = UIImage(cgImage: rightCG, scale: image.scale, orientation: image.imageOrientation)
        
        // 3. Return based on reading direction
        if isManga {
            // Manga is read Right-to-Left, so the Right half is Page 1
            return [rightPage, leftPage]
        } else {
            // Western comics are Left-to-Right
            return [leftPage, rightPage]
        }
    }
}
