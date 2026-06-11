import UIKit

struct ImageProcessor {
    
    // Process a single image from disk based on settings
    static func process(imageURL: URL, settings: ConversionSettings, isOddPage: Bool = true) -> UIImage? {
        guard let image = UIImage(contentsOfFile: imageURL.path) else { return nil }
        return process(image: image, settings: settings, isOddPage: isOddPage)
    }

    // Process a single in-memory image based on settings
    static func process(image: UIImage, settings: ConversionSettings, isOddPage: Bool = true) -> UIImage? {
        return EInkOptimizer.shared.processImage(image, settings: settings, isOddPage: isOddPage)
    }
    
    // MARK: - Helper Functions
    
    /// Bakes the UIImage orientation into the raw pixel data so downstream CGImage/vImage 
    /// functions don't invert or rotate the image unexpectedly.
    static func fixOrientation(of image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(at: .zero) }
    }
    
    static func crop(image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let cropRect = CGRect(
            x: rect.minX * width,
            y: (1.0 - rect.maxY) * height,
            width: rect.width * width,
            height: rect.height * height
        )
        
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
    
    // MARK: - Webtoon Slicing
    
    /// Slices a tall Webtoon image into multiple Kindle-optimized pages.
    /// Uses an overlap method to ensure text isn't lost across page breaks.
    /// - Parameters:
    ///   - image: The original vertical strip.
    ///   - targetAspectRatio: Height / Width ratio (e.g., 1.33 for standard Kindle 4:3).
    /// - Returns: An array of sliced UIImages.
    static func sliceWebtoon(image: UIImage, targetAspectRatio: CGFloat = 1.33) -> [UIImage] {
        guard let cgImage = image.cgImage else {
            Logger.shared.log("sliceWebtoon: cgImage unavailable, returning original image", category: "Webtoon", type: .warning)
            return [image]
        }
        
        let width = CGFloat(cgImage.width)
        let totalHeight = CGFloat(cgImage.height)
        
        // If the image is already roughly page-sized or smaller, don't slice
        if totalHeight / width <= targetAspectRatio * 1.2 {
            return [image]
        }
        
        var slices: [UIImage] = []
        let targetHeight = width * targetAspectRatio
        let minOverlap = targetHeight * 0.08 // 8% overlap if we can't find a clean cut
        
        var currentY: CGFloat = 0
        
        while currentY < totalHeight {
            var sliceHeight = targetHeight
            
            // If we're near the bottom, just take the rest of the image
            if currentY + sliceHeight >= totalHeight {
                sliceHeight = totalHeight - currentY
            }
            
            let cropRect = CGRect(x: 0, y: currentY, width: width, height: sliceHeight)
            if let croppedCG = cgImage.cropping(to: cropRect) {
                let sliceImage = UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
                slices.append(sliceImage)
            } else {
                Logger.shared.log("sliceWebtoon: crop failed at y=\(Int(currentY)), h=\(Int(sliceHeight)) — skipping slice", category: "Webtoon", type: .error)
            }
            
            if currentY + sliceHeight >= totalHeight {
                break
            }
            
            // Move down, but step back by the overlap amount so context is preserved across the cut
            currentY += (sliceHeight - minOverlap)
        }
        
        Logger.shared.log("sliceWebtoon: \(slices.count) slices produced from \(Int(totalHeight))px tall image", category: "Webtoon")
        return slices
    }

    /// Hard-slices a landscape double-page spread into two portrait pages.
    /// Crucially respects manga reading direction.
    /// - Parameters:
    ///   - image: The landscape double-page spread.
    ///   - isManga: If true (RTL), the RIGHT half becomes page 1.
    /// - Returns: An array of sliced UIImages in the correct reading order.
    static func sliceSpread(image: UIImage, isManga: Bool) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        if width <= height * 1.1 {
            return [image] // Not a spread, ignore
        }
        
        let halfWidth = width / 2.0
        
        let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
        let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)
        
        var slices: [UIImage] = []
        
        let leftSlice = cgImage.cropping(to: leftRect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) }
        let rightSlice = cgImage.cropping(to: rightRect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) }
        
        guard let left = leftSlice, let right = rightSlice else { return [image] }
        
        if isManga {
            slices = [right, left] // RTL: Read right page first
            Logger.shared.log("Sliced Double Spread (Manga Mode): Right half is Page 1", category: "Converter")
        } else {
            slices = [left, right] // LTR: Read left page first
            Logger.shared.log("Sliced Double Spread (Standard): Left half is Page 1", category: "Converter")
        }
        
        return slices
    }
}
