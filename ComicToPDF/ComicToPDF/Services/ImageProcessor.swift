import UIKit

struct ImageProcessor {
    static func processPage(_ image: UIImage, splitSpreads: Bool, isManga: Bool) -> [UIImage] {
        // If splitting is disabled or image is Portrait/Square, return original
        if !splitSpreads || image.size.height >= image.size.width {
            return [image]
        }
        
        // It's a Landscape Spread -> Split it!
        let width = image.size.width
        let height = image.size.height
        let halfWidth = width / 2.0
        
        // Create Crop Rects
        let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
        let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)
        
        guard let cgImage = image.cgImage,
              let leftCG = cgImage.cropping(to: leftRect),
              let rightCG = cgImage.cropping(to: rightRect) else {
            return [image] // Fallback if crop fails
        }
        
        let leftPage = UIImage(cgImage: leftCG)
        let rightPage = UIImage(cgImage: rightCG)
        
        // Manga (RTL): Right side is Page 1, Left side is Page 2
        // Western (LTR): Left side is Page 1, Right side is Page 2
        if isManga {
            return [rightPage, leftPage]
        } else {
            return [leftPage, rightPage]
        }
    }
}
