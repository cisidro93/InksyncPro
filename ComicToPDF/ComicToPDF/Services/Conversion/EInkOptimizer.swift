import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Optimized Image Processor for E-Ink Displays
/// Mathematically scales down images to device-native resolutions to prevent on-the-fly rendering lag
/// and optionally applies hardware-accelerated CI filters to boost contrast and strip color saturation.
final class EInkOptimizer: @unchecked Sendable {
    static let shared = EInkOptimizer()
    
    // Hardware-accelerated context
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    private init() {}
    
    /// Processes a UIImage for the specified target device profile and grayscale preference
    func processImage(_ image: UIImage, for profile: TargetDeviceProfile, applyGrayscale: Bool, cropMargins: Bool = false, reduceMoire: Bool = false, dither: Bool = false, marginOffset: Int = 0, marginSide: BindingMarginSide = .none, isOddPage: Bool = true, customTargetSize: CGSize? = nil) -> UIImage {
        // Handle Edge Case: Profile = Original and Grayscale = False and cropMargins = False and reduceMoire = False and dither = False and marginOffset = 0 and no customTargetSize
        if profile == .original && !applyGrayscale && !cropMargins && !reduceMoire && !dither && marginOffset == 0 && customTargetSize == nil {
            return image
        }
        
        var workingImage = image
        var processedMoire = false
        
        // 0. Trim Blank Margins First (so scaling maximizes the actual artwork)
        if cropMargins {
            workingImage = autoCropImage(workingImage)
        }
        
        // 1. Moiré Reduction (Pre-scaling step: Slight Gaussian Blur to kill screentone frequency)
        if reduceMoire {
            workingImage = applyMoireReduction(to: workingImage)
            processedMoire = true
        }
        
        // 3. Aspect-Fit Downsampling
        if let targetSize = customTargetSize ?? profile.resolution {
            let originalSize = workingImage.size
            if customTargetSize != nil || originalSize.width > targetSize.width || originalSize.height > targetSize.height {
                var safeTargetSize = targetSize
                // Dynamic Orientation-Aware Scaling!
                // If the original image is naturally a landscape spread, we flip the 
                // device hardware limits horizontally to avoid crushing max width to portrait constraints!
                if customTargetSize == nil && originalSize.width > originalSize.height {
                    safeTargetSize = CGSize(width: max(targetSize.width, targetSize.height), height: min(targetSize.width, targetSize.height))
                }
                workingImage = scale(workingImage, toFit: safeTargetSize)
            }
        }
        
        // 4. Asymmetric Binding Margins (Gutter Space)
        // We apply this AFTER downsampling so the specific point values map 1:1 to the native device resolution
        if marginOffset > 0 && marginSide != .none {
            workingImage = applyBindingMargin(to: workingImage, offset: CGFloat(marginOffset), side: marginSide, isOddPage: isOddPage)
        }
        
        // 5. Hardware-Accelerated E-Ink Grayscale Filter
        if applyGrayscale {
            workingImage = applyEInkFilter(to: workingImage, dither: dither, reSharpen: processedMoire)
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
    
    /// Pads the image with white space on the specified side
    private func applyBindingMargin(to image: UIImage, offset: CGFloat, side: BindingMarginSide, isOddPage: Bool) -> UIImage {
        let originalSize = image.size
        let newWidth = originalSize.width + offset
        let newSize = CGSize(width: newWidth, height: originalSize.height)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        
        var drawX: CGFloat = 0
        
        // Determine which side gets the padding
        switch side {
        case .left:
            drawX = offset // Pad left, image starts further right
        case .right:
            drawX = 0      // Pad right, image starts at 0, canvas is wider
        case .alternating:
            // Odd pages get padded on the left (if LTR) or right (if manga). 
            // Usually, page 1 is the right half of an open book. So binding margin is on its left.
            if isOddPage {
                drawX = offset
            } else {
                drawX = 0
            }
        case .none:
            return image
        }
        
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            // Fill background with white (Standard for E-readers)
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: newSize))
            
            // Draw original image shifted by drawX
            image.draw(in: CGRect(x: drawX, y: 0, width: originalSize.width, height: originalSize.height))
        }
    }
    
    /// Uses CoreImage to strip the color channel, boost the contrast, and optionally Dither
    private func applyEInkFilter(to image: UIImage, dither: Bool, reSharpen: Bool) -> UIImage {
        guard let cgImage = image.cgImage else {
            Logger.shared.log("EInkOptimizer: Failed to extract CGImage for grayscale", category: "EInk", type: .warning)
            return image
        }
        var currentCIImage = CIImage(cgImage: cgImage)
        
        // A. Resharpen if we blurred for Moire earlier to restore edges
        if reSharpen, let sharpenFilter = CIFilter(name: "CIUnsharpMask") {
            sharpenFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(1.5, forKey: kCIInputRadiusKey)
            sharpenFilter.setValue(0.5, forKey: kCIInputIntensityKey)
            if let out = sharpenFilter.outputImage {
                currentCIImage = out
            }
        }
        
        // B. Color Controls Filter (Contrast Boost, Saturation Strip)
        guard let colorFilter = CIFilter(name: "CIColorControls") else {
            return image
        }
        colorFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
        colorFilter.setValue(0.0, forKey: kCIInputSaturationKey) // Grayscale
        colorFilter.setValue(1.15, forKey: kCIInputContrastKey)  // Boost contrast 15% to prevent washed out text
        
        guard var outputImage = colorFilter.outputImage else {
            return image
        }
        
        // C. Hardware Dithering (Ordered Dithering mapped to 16 Gray levels for E-ink)
        // CoreImage has CbDither but standard generic way is to posterize to 16 levels via ColorPosterize
        if dither, let posterizeFilter = CIFilter(name: "CIColorPosterize") {
            posterizeFilter.setValue(outputImage, forKey: kCIInputImageKey)
            posterizeFilter.setValue(16.0, forKey: "inputLevels") // 16 shades of gray exactly like a Kindle natively supports
            if let posterizedOut = posterizeFilter.outputImage {
                 // Add subtle noise before posterize to emulate Floyd-Steinberg error diffusion visually 
                 // (True FS is sequential CPU, but GPU posterize with a pre-noise pass looks incredibly similar)
                 // We would blend noise here. Standard ColorPosterize 16 is sufficient for massive E-Ink improvements for now.
                 outputImage = posterizedOut
            }
        }
        
        // 2. Render back to UIImage via Context
        guard let finalCGImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: finalCGImage)
    }
    
    /// Pre-scaling slight blur to eliminate high-frequency screentone matrices before they cause interference patterns
    private func applyMoireReduction(to image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(1.0, forKey: kCIInputRadiusKey) // Very slight blur
        
        guard let output = blurFilter.outputImage, let finalCG = context.createCGImage(output, from: ciImage.extent) else { return image }
        return UIImage(cgImage: finalCG)
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
        
        // Threshold for "white" (0 is black, 255 is white)
        // We consider anything less than 250 to be content
        let threshold: UInt8 = 250
        let strideVal = 8
        
        // 1. Find minY (top-down)
        var minY = height
        var foundTopRow = -1
        for y in stride(from: 0, to: height, by: strideVal) {
            let rowOffset = y * bytesPerRow
            var found = false
            for x in stride(from: 0, to: width, by: 8) {
                if rawData[rowOffset + x] < threshold {
                    found = true
                    break
                }
            }
            if found {
                foundTopRow = y
                break
            }
        }
        if foundTopRow != -1 {
            let startY = max(0, foundTopRow - strideVal + 1)
            for y in startY...foundTopRow {
                let rowOffset = y * bytesPerRow
                var found = false
                for x in 0..<width {
                    if rawData[rowOffset + x] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    minY = y
                    break
                }
            }
        }
        
        // 2. Find maxY (bottom-up)
        var maxY = -1
        var foundBottomRow = -1
        if minY < height {
            for y in stride(from: height - 1, through: minY, by: -strideVal) {
                let rowOffset = y * bytesPerRow
                var found = false
                for x in stride(from: 0, to: width, by: 8) {
                    if rawData[rowOffset + x] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    foundBottomRow = y
                    break
                }
            }
        }
        if foundBottomRow != -1 {
            let startY = min(height - 1, foundBottomRow + strideVal - 1)
            for y in stride(from: startY, through: foundBottomRow, by: -1) {
                let rowOffset = y * bytesPerRow
                var found = false
                for x in 0..<width {
                    if rawData[rowOffset + x] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    maxY = y
                    break
                }
            }
        }
        
        if minY > maxY || minY == height || maxY == -1 {
            return cgImage
        }
        
        // 3. Find minX (left-to-right)
        var minX = width
        var foundLeftCol = -1
        for x in stride(from: 0, to: width, by: strideVal) {
            var found = false
            for y in stride(from: minY, to: maxY, by: 8) {
                if rawData[y * bytesPerRow + x] < threshold {
                    found = true
                    break
                }
            }
            if found {
                foundLeftCol = x
                break
            }
        }
        if foundLeftCol != -1 {
            let startX = max(0, foundLeftCol - strideVal + 1)
            for x in startX...foundLeftCol {
                var found = false
                for y in minY...maxY {
                    if rawData[y * bytesPerRow + x] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    minX = x
                    break
                }
            }
        }
        
        // 4. Find maxX (right-to-left)
        var maxX = -1
        var foundRightCol = -1
        if minX < width {
            for x in stride(from: width - 1, through: minX, by: -strideVal) {
                var found = false
                for y in stride(from: minY, to: maxY, by: 8) {
                    if rawData[y * bytesPerRow + x] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    foundRightCol = x
                    break
                }
            }
        }
        if foundRightCol != -1 {
            let startX = min(width - 1, foundRightCol + strideVal - 1)
            for x in stride(from: startX, through: foundRightCol, by: -1) {
                var found = false
                for y in minY...maxY {
                    if rawData[y * bytesPerRow + x] < threshold {
                        maxX = x
                        found = true
                        break
                    }
                }
                if found { break }
            }
        }
        
        if minX > maxX || minX == width || maxX == -1 {
            return cgImage
        }
        
        // True Edge-to-Edge: 0% padding
        let paddingX = 0
        let paddingY = 0
        
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
