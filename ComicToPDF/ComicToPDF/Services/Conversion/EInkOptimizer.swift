import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Optimized Image Processor for E-Ink Displays
/// Mathematically scales down images to device-native resolutions to prevent on-the-fly rendering lag
/// and optionally applies hardware-accelerated CI filters to boost contrast and strip color saturation.
class EInkOptimizer {
    static let shared = EInkOptimizer()
    
    // Hardware-accelerated context
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    private init() {}
    
    /// Processes a UIImage for the specified target device profile and grayscale preference
    func processImage(_ image: UIImage, for profile: TargetDeviceProfile, applyGrayscale: Bool, cropMargins: Bool = false) -> UIImage {
        // Handle Edge Case: Profile = Original and Grayscale = False and cropMargins = False
        if profile == .original && !applyGrayscale && !cropMargins {
            return image
        }
        
        var workingImage = image
        
        // 0. Trim Blank Margins First (so scaling maximizes the actual artwork)
        if cropMargins {
            workingImage = autoCropImage(workingImage)
        }
        
        // 1. Aspect-Fit Downsampling
        if let targetSize = profile.resolution {
            let originalSize = workingImage.size
            if originalSize.width > targetSize.width || originalSize.height > targetSize.height {
                workingImage = scale(workingImage, toFit: targetSize)
            }
        }
        
        // 2. Hardware-Accelerated E-Ink Grayscale Filter
        if applyGrayscale {
            workingImage = applyEInkFilter(to: workingImage)
        }
        
        return workingImage
    }
    
    /// Mathematically scales a UIImage using UIGraphicsImageRenderer boundary
    private func scale(_ image: UIImage, toFit targetSize: CGSize) -> UIImage {
        let originalSize = image.size
        let widthRatio  = targetSize.width  / originalSize.width
        let heightRatio = targetSize.height / originalSize.height
        
        // Aspect Fit
        let factor = min(widthRatio, heightRatio)
        let renderSize = CGSize(width: originalSize.width * factor, height: originalSize.height * factor)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // 1 pixel = 1 point mapping
        
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }
    
    /// Uses CoreImage to strip the color channel and boost the contrast
    private func applyEInkFilter(to image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else {
            Logger.shared.log("EInkOptimizer: Failed to extract CGImage for grayscale", category: "EInk", type: .warning)
            return image
        }
        let ciImage = CIImage(cgImage: cgImage)
        
        // 1. Color Controls Filter (Contrast Boost, Saturation Strip)
        guard let colorFilter = CIFilter(name: "CIColorControls") else {
            Logger.shared.log("EInkOptimizer: CIColorControls filter unavailable", category: "EInk", type: .error)
            return image
        }
        colorFilter.setValue(ciImage, forKey: kCIInputImageKey)
        colorFilter.setValue(0.0, forKey: kCIInputSaturationKey) // Grayscale
        colorFilter.setValue(1.15, forKey: kCIInputContrastKey)  // Boost contrast 15% to prevent washed out text
        
        guard let outputImage = colorFilter.outputImage else {
            Logger.shared.log("EInkOptimizer: Filter produced no output image", category: "EInk", type: .error)
            return image
        }
        
        // 2. Render back to UIImage via Context
        guard let finalCGImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            Logger.shared.log("EInkOptimizer: Failed to render CGImage from context", category: "EInk", type: .error)
            return image
        }
        
        return UIImage(cgImage: finalCGImage)
    }
    
    /// Auto-trims white/blank margins from the edges of a comic page
    private func autoCropImage(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else {
            Logger.shared.log("EInkOptimizer: Failed to extract CGImage for auto-crop", category: "EInk", type: .warning)
            return image
        }
        let ciImage = CIImage(cgImage: cgImage)
        
        // Use CoreImage built-in crop to bounding box based on alpha/color
        guard let customExtract = CIFilter(name: "CIMaskToAlpha") else { return image }
        customExtract.setValue(ciImage, forKey: kCIInputImageKey)
        
        // While CIMaskToAlpha is useful, usually manga borders are pure white.
        // A more robust CoreImage technique for trimming whitespace:
        _ = ciImage.extent
        
        // We will just use the standard image since CoreImage doesn't have a reliable automatic "trim white margin" filter out of the box without complex histogram analysis.
        // Instead, we will simulate it by querying CoreGraphics context bounding box.
        // Since full pixel-by-pixel scanning is slow, we will use a CIFilter to detect edges.
        
        // For performance, we'll try a simpler approach right now if we need high speed, but since this runs per-image, a robust CGImage boundary scan is best.
        let croppedCGImage = cropToContent(cgImage)
        return UIImage(cgImage: croppedCGImage)
    }
    
    private func cropToContent(_ cgImage: CGImage) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        var rawData = [UInt8](repeating: 0, count: width * height)
        let bytesPerPixel = 1
        let bytesPerRow = width * bytesPerPixel
        
        guard let context = CGContext(data: &rawData, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return cgImage
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        
        // Threshold for "white" (0 is black, 255 is white)
        // We consider anything less than 250 to be content
        let threshold: UInt8 = 250
        
        for y in 0..<height {
            var rowHasContent = false
            for x in 0..<width {
                let pixelIndex = (y * bytesPerRow) + x
                let pixelValue = rawData[pixelIndex]
                
                if pixelValue < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    rowHasContent = true
                }
            }
            if rowHasContent {
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        
        // If the entire image is white or the crop box is invalid, return original
        if minX > maxX || minY > maxY {
            return cgImage
        }
        
        // Add a slight 2% padding back so it's not literally touching the edge
        let paddingX = Int(Double(width) * 0.02)
        let paddingY = Int(Double(height) * 0.02)
        
        let finalX = max(0, minX - paddingX)
        let finalY = max(0, minY - paddingY)
        let finalWidth = min(width - finalX, (maxX - minX) + (paddingX * 2))
        let finalHeight = min(height - finalY, (maxY - minY) + (paddingY * 2))
        
        let cropRect = CGRect(x: finalX, y: height - finalY - finalHeight, width: finalWidth, height: finalHeight) // Invert Y for CGImage
        
        if let cropped = cgImage.cropping(to: cropRect) {
            return cropped
        }
        
        return cgImage
    }
}
