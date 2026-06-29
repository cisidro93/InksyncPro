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
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard // Forces standard sRGB color space
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
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
    
    // MARK: - Color Space Conversion & Verification
    
    /// Checks if a UIImage uses a wide color space (Display P3, Adobe RGB, etc.).
    /// Handles deferred-decoding images by drawing them into a graphics context if cgImage is nil.
    static func isWideColor(_ image: UIImage) -> Bool {
        let cgImageToUse: CGImage?
        if let cg = image.cgImage {
            cgImageToUse = cg
        } else {
            // Draw to a temporary context to get a CGImage
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.preferredRange = .automatic // Keep original color space
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            let renderedImage = renderer.image { _ in image.draw(at: .zero) }
            cgImageToUse = renderedImage.cgImage
        }
        
        guard let cgImage = cgImageToUse, let colorSpace = cgImage.colorSpace else { return false }
        
        if let name = colorSpace.name {
            let nameStr = name as String
            if nameStr.localizedCaseInsensitiveContains("p3") {
                return true
            }
        }
        
        let desc = String(describing: colorSpace).lowercased()
        if desc.contains("p3") || desc.contains("display") || desc.contains("adobe") {
            return true
        }
        
        return false
    }
    
    /// Checks if an image file at URL uses a wide color space without full decompression.
    static func isWideColor(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        guard let colorSpace = cgImage.colorSpace else { return false }
        
        if let name = colorSpace.name {
            let nameStr = name as String
            if nameStr.localizedCaseInsensitiveContains("p3") {
                return true
            }
        }
        
        let desc = String(describing: colorSpace).lowercased()
        if desc.contains("p3") || desc.contains("display") || desc.contains("adobe") {
            return true
        }
        
        return false
    }
    
    /// Checks if image data uses a wide color space without full decompression.
    static func isWideColor(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        guard let colorSpace = cgImage.colorSpace else { return false }
        
        if let name = colorSpace.name {
            let nameStr = name as String
            if nameStr.localizedCaseInsensitiveContains("p3") {
                return true
            }
        }
        
        let desc = String(describing: colorSpace).lowercased()
        if desc.contains("p3") || desc.contains("display") || desc.contains("adobe") {
            return true
        }
        
        return false
    }
    
    /// Converts a UIImage to sRGB space if it is wide-color.
    static func convertToSRGB(_ image: UIImage) -> UIImage {
        if !isWideColor(image) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard // Forces standard sRGB color space
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(at: .zero) }
    }
    
    /// Converts image data to sRGB space if it is wide-color.
    static func convertToSRGB(data: Data, quality: CGFloat = 0.9) -> Data {
        if !isWideColor(data: data) { return data }
        guard let image = UIImage(data: data) else { return data }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let srgbImage = renderer.image { _ in image.draw(at: .zero) }
        return srgbImage.jpegData(compressionQuality: quality) ?? data
    }
}

