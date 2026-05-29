import UIKit
import Accelerate

struct ImageProcessor {
    
    // ✅ Performance Optimization: Shared Hardware-Accelerated Context
    // Prevents creating 1000+ GPU contexts during batch processing which kills battery
    private static nonisolated(unsafe) let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    
    // Process a single image from disk based on settings
    static func process(imageURL: URL, settings: ConversionSettings) -> UIImage? {
        guard let image = UIImage(contentsOfFile: imageURL.path) else { return nil }
        return process(image: image, settings: settings)
    }

    // Process a single in-memory image based on settings
    static func process(image: UIImage, settings: ConversionSettings) -> UIImage? {
        // 0. Ensure Upright Orientation Before GPU/Math processing
        // vImage and CoreImage strip UI orientation metadata, so we must bake the pixels upright first.
        // Guard skips UIGraphicsImageRenderer allocation for the common .up case (most comic pages).
        var finalImage = image.imageOrientation == .up ? image : (fixOrientation(of: image) ?? image)
        
        // 0.5. Smart Margin Removal (Full-Bleed) - ✅ NEW
        if settings.trimMargins {
            if let cropRect = SmartCropper.suggestCrop(for: finalImage) {
                // Apply the crop
                if let cropped = crop(image: finalImage, to: cropRect) {
                    finalImage = cropped
                }
            }
        }
        
        // 1. Resize if needed (Optimize for Device or Compact Mode)
        let needsResize = settings.optimizeForDevice || settings.compressionQuality == .compact
        
        if needsResize {
            // Get target resolution (Default to a 1440x1920 HD equivalent for 'Compact' if no device selected)
            let defaultSize = CGSize(width: 1440, height: 1920)
            let targetSize = (settings.optimizeForDevice ? settings.targetDeviceProfile.resolution : defaultSize) ?? defaultSize
            
            // Use vImage for high-performance resizing
            // Downsampling only. We do NOT forcefully burn in letterbox/pillarbox padding here anymore.
            // SVG 'preserveAspectRatio' will handle dynamic viewport centering at the presentation layer.
            if let resized = resize(image: finalImage, toFit: targetSize) {
                finalImage = resized
            }
        }
        
        if settings.imageEnhancement.grayscale {
            if let grayscaled = convertToGrayscale(image: finalImage) {
                finalImage = grayscaled
            }
        }
        
        if settings.imageEnhancement.invertColors {
            if let inverted = applyInvertColors(image: finalImage) {
                finalImage = inverted
            }
        }
        
        if settings.imageEnhancement.autoContrast {
            // Intelligent Histogram Stretching (Auto-Levels) for deeper blacks and purer whites
            if let stretched = applyHistogramStretch(image: finalImage) {
                 finalImage = stretched
            }
        }
        
        // 3. E-Ink Unsharp Masking (Crisp Line Art & Text)
        if settings.imageEnhancement.sharpness > 0 {
            finalImage = applyUnsharpMask(image: finalImage, intensity: settings.imageEnhancement.sharpness)
        }
        
        // 4. Brightness & Color Vibrance (Combats Kaleido/Colorsoft washed out look)
        if settings.imageEnhancement.brightness != 0.0 || settings.imageEnhancement.vibrance != 0.0 {
            finalImage = applyBrightnessAndVibrance(image: finalImage, brightness: settings.imageEnhancement.brightness, vibrance: settings.imageEnhancement.vibrance)
        }
        
        // 3. Gamma Correction (KCC Feature for E-Ink)
        // Default is 1.0 (No change). E-Ink usually benefits from ~0.7 to lighten shadows or ~1.2 to darken text.
        if settings.imageEnhancement.gamma != 1.0 {
            finalImage = applyGamma(image: finalImage, gamma: settings.imageEnhancement.gamma)
        }
        
        return finalImage
    }
    
    // MARK: - Helper Functions
    
    /// Bakes the UIImage orientation into the raw pixel data so downstream CGImage/vImage 
    /// functions don't invert or rotate the image unexpectedly.
    static func fixOrientation(of image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        // UIGraphicsImageRenderer uses Metal-backed rendering and is not deprecated on iOS 17+.
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
            // This is the professional, fail-safe way to ensure dialog bubbles aren't lost
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
        
        // Only split if it is genuinely a landscape spread (width significantly > height)
        if width <= height * 1.1 {
            return [image] // Not a spread, ignore
        }
        
        // Find the middle. Some scanners add a gutter, we slice exactly down the middle
        let halfWidth = width / 2.0
        
        // Left Half
        let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
        // Right Half
        let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)
        
        var slices: [UIImage] = []
        
        let leftSlice = cgImage.cropping(to: leftRect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) }
        let rightSlice = cgImage.cropping(to: rightRect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) }
        
        guard let left = leftSlice, let right = rightSlice else { return [image] }
        
        // The most critical part for competitors: Manga Mode determines the split order!
        if isManga {
            slices = [right, left] // RTL: Read right page first
            Logger.shared.log("Sliced Double Spread (Manga Mode): Right half is Page 1", category: "Converter")
        } else {
            slices = [left, right] // LTR: Read left page first
            Logger.shared.log("Sliced Double Spread (Standard): Left half is Page 1", category: "Converter")
        }
        
        return slices
    }

    /// High-performance resizing using vImage
    private static func resize(image: UIImage, toFit targetSize: CGSize) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        
        let widthRatio = targetSize.width / CGFloat(cgImage.width)
        let heightRatio = targetSize.height / CGFloat(cgImage.height)
        let scaleFactor = min(widthRatio, heightRatio)
        
        // Don't upscale small images
        if scaleFactor >= 1.0 { return image }
        
        let newWidth = Int(CGFloat(cgImage.width) * scaleFactor)
        let newHeight = Int(CGFloat(cgImage.height) * scaleFactor)
        
        // 1. Create Source Buffer
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil, // Default sRGB
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue), // ARGB
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return image }
        defer { free(sourceBuffer.data) }
        
        // 2. Create Destination Buffer
        var destinationBuffer = vImage_Buffer()
        error = vImageBuffer_Init(&destinationBuffer, vImagePixelCount(newHeight), vImagePixelCount(newWidth), 32, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return image }
        defer { free(destinationBuffer.data) }
        
        // 3. Perform Scale
        error = vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { return image }
        
        // 4. Create Image from Buffer
        let resizedCGImage = vImageCreateCGImageFromBuffer(&destinationBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
        
        guard error == kvImageNoError, let result = resizedCGImage else { return image }
        return UIImage(cgImage: result.takeRetainedValue())
    }
    
    /// High-performance padding using CoreGraphics to force exact Kindle Aspect Ratio.
    /// This mimics KCC's "Full Bleed" trick to prevent the Kindle Reflowable engine from injecting white borders.
    private static func pad(image: UIImage, toFitAspectOf targetSize: CGSize, isManga: Bool) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        
        let targetAspect = targetSize.width / targetSize.height
        let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        
        // If it's already a perfect match, skip.
        if abs(targetAspect - imageAspect) < 0.01 { return image }
        
        let canvasWidth: CGFloat
        let canvasHeight: CGFloat
        let drawRect: CGRect
        
        if imageAspect > targetAspect {
            // Image is wider than screen -> Letterbox (Pad Top/Bottom)
            canvasWidth = CGFloat(cgImage.width)
            canvasHeight = canvasWidth / targetAspect
            let yOffset = (canvasHeight - CGFloat(cgImage.height)) / 2.0
            drawRect = CGRect(x: 0, y: yOffset, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        } else {
            // Image is taller than screen -> Pillarbox (Pad Left/Right)
            canvasHeight = CGFloat(cgImage.height)
            canvasWidth = canvasHeight * targetAspect
            let xOffset = (canvasWidth - CGFloat(cgImage.width)) / 2.0
            drawRect = CGRect(x: xOffset, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        }
        
        // Use vImage to avoid memory spikes with UIGraphicsImageRenderer
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), // Faster for opaque
            version: 0, decode: nil, renderingIntent: .defaultIntent
        )
        
        var canvasBuffer = vImage_Buffer()
        var error = vImageBuffer_Init(&canvasBuffer, vImagePixelCount(canvasHeight), vImagePixelCount(canvasWidth), 32, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return image }
        defer { free(canvasBuffer.data) }
        
        // Fill Canvas with Black (ARGB: 255, 0, 0, 0)
        _ = [UInt8]([0, 0, 0, 0]) // Actually XRGB where X is ignored but commonly 0 or 255
        // Using vImageBufferFill_ARGB8888 is deprecated, so we just clear it (which is black)
        // memset(canvasBuffer.data, 0, canvasBuffer.rowBytes * Int(canvasHeight)) is already black!
        memset(canvasBuffer.data, 0, canvasBuffer.rowBytes * Int(canvasHeight))
        
        // Create CGContext over the vImage buffer to draw the original image
        guard let context = CGContext(
            data: canvasBuffer.data,
            width: Int(canvasWidth),
            height: Int(canvasHeight),
            bitsPerComponent: 8,
            bytesPerRow: canvasBuffer.rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        
        // Fill black explicitly just to be safe
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        
        // Draw Image into the calculated rect
        context.draw(cgImage, in: drawRect)
        
        let paddedCGImage = vImageCreateCGImageFromBuffer(&canvasBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
        guard error == kvImageNoError, let result = paddedCGImage else { return image }
        
        return UIImage(cgImage: result.takeRetainedValue())
    }
    
    /// High-performance grayscale conversion using vImage Matrix Multiply
    private static func convertToGrayscale(image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        
        // 1. Create Source Buffer
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue), // ARGB
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return image }
        defer { free(sourceBuffer.data) }
        
        // 2. Create Destination Buffer
        var destinationBuffer = vImage_Buffer()
        error = vImageBuffer_Init(&destinationBuffer, sourceBuffer.height, sourceBuffer.width, 32, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return image }
        defer { free(destinationBuffer.data) }
        
        // 3. Matrix Multiplication (Rec. 709 Luma: R*0.2126 + G*0.7152 + B*0.0722)
        // Matrix is 4x4:
        // OutputA = A*1 + R*0 + G*0 + B*0
        // OutputR = A*0 + R*c + G*c + B*c
        // OutputG = A*0 + R*c + G*c + B*c
        // OutputB = A*0 + R*c + G*c + B*c
        // Note: ARGB format implies channel order A, R, G, B
        
        let r: Float = 0.2126
        let g: Float = 0.7152
        let b: Float = 0.0722
        
        let matrix: [Float] = [
            1.0, 0.0, 0.0, 0.0, // Alpha out
            0.0, r,   g,   b,   // Red out
            0.0, r,   g,   b,   // Green out
            0.0, r,   g,   b    // Blue out
        ]
        
        let divisor: Int32 = 256
        let matrix16 = matrix.map { Int16($0 * Float(divisor)) }
        
        error = vImageMatrixMultiply_ARGB8888(&sourceBuffer, &destinationBuffer, matrix16, divisor, nil, nil, vImage_Flags(kvImageNoFlags))
         guard error == kvImageNoError else { return image }

        // 4. Create Image from Buffer
        let resultCGImage = vImageCreateCGImageFromBuffer(&destinationBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
        
        guard error == kvImageNoError, let result = resultCGImage else { return image }
        return UIImage(cgImage: result.takeRetainedValue())
    }
    
    private static func applyInvertColors(image: UIImage) -> UIImage? {
        guard let customCIImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIColorInvert")
        filter?.setValue(customCIImage, forKey: kCIInputImageKey)
        
        guard let output = filter?.outputImage else { return image }
        
        guard let cgImg = sharedCIContext.createCGImage(output, from: output.extent) else { return image }
        
        return UIImage(cgImage: cgImg)
    }
    
    // MARK: - E-Ink Intelligent Enhancements
    
    /// True Histogram Stretching using vImage for deep blacks and pure whites without crushing midtones.
    private static func applyHistogramStretch(image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue), // ARGB
            version: 0, decode: nil, renderingIntent: .defaultIntent
        )
        
        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }
        
        var destBuffer = vImage_Buffer()
        error = vImageBuffer_Init(&destBuffer, sourceBuffer.height, sourceBuffer.width, 32, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(destBuffer.data) }
        
        // Contrast Stretch maps the darkest pixels to 0 and the lightest to 255
        error = vImageContrastStretch_ARGB8888(&sourceBuffer, &destBuffer, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        
        let resultCGImage = vImageCreateCGImageFromBuffer(&destBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
        guard error == kvImageNoError, let result = resultCGImage else { return nil }
        
        return UIImage(cgImage: result.takeRetainedValue())
    }
    
    /// Compensates for physical E-Ink blur by crisping up line art and dialogue text.
    private static func applyUnsharpMask(image: UIImage, intensity: Double) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIUnsharpMask")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        // Map 0.0 - 1.0 to reasonable Unsharp params (Radius 2.5 is good for comics)
        filter?.setValue(2.5, forKey: kCIInputRadiusKey)
        filter?.setValue(intensity * 2.0, forKey: kCIInputIntensityKey) 
        
        guard let output = filter?.outputImage,
              let cgImage = sharedCIContext.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }
    
    /// Adjusts Brightness and pushes Vibrance (Saturation) to counteract Color E-Ink washed out panels.
    private static func applyBrightnessAndVibrance(image: UIImage, brightness: Double, vibrance: Double) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(brightness, forKey: kCIInputBrightnessKey)
        // Map 0.0 - 1.0 vibrance slider to a 1.0 (normal) to 2.0 (super saturated) multiplier
        filter?.setValue(1.0 + vibrance, forKey: kCIInputSaturationKey)
        
        guard let output = filter?.outputImage,
              let cgImage = sharedCIContext.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }
    
    private static func applyGamma(image: UIImage, gamma: Double) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIGammaAdjust")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(gamma, forKey: "inputPower")
        
        if let output = filter?.outputImage,
           let cgImage = sharedCIContext.createCGImage(output, from: output.extent) {
            return UIImage(cgImage: cgImage)
        }
        return image
    }
}
