import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

/// Optimized Image Processor for E-Ink Displays
/// Mathematically scales down images to device-native resolutions to prevent on-the-fly rendering lag
/// and applies hardware-accelerated CI filters and vImage functions to boost contrast, strip color,
/// and apply noise-based ordered dithering.
final class EInkOptimizer: @unchecked Sendable {
    static let shared = EInkOptimizer()
    
    // Hardware-accelerated context
    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    
    private init() {}
    
    /// Processes a UIImage for the specified target device profile and conversion settings
    func processImage(
        _ image: UIImage,
        settings: ConversionSettings,
        isOddPage: Bool = true,
        customTargetSize: CGSize? = nil
    ) -> UIImage {
        let effectiveMaxDim = settings.compressionQuality.maxDimension
        let presetTargetSize = (effectiveMaxDim.map { CGSize(width: $0, height: $0) }) ?? settings.targetDeviceProfile.resolution
        let targetSizeToUse = customTargetSize ?? presetTargetSize

        // Fast-path: return original image if no processing is requested
        if settings.targetDeviceProfile == .original
            && settings.compressionQuality.maxDimension == nil
            && !settings.imageEnhancement.grayscale
            && !settings.trimMargins
            && !settings.imageEnhancement.reduceMoire
            && !settings.imageEnhancement.ditheringEnabled
            && settings.bindingMarginOffset == 0
            && !settings.imageEnhancement.invertColors
            && !settings.imageEnhancement.autoContrast
            && settings.imageEnhancement.brightness == 0.0
            && settings.imageEnhancement.sharpness == 0.0
            && settings.imageEnhancement.vibrance == 0.0
            && settings.imageEnhancement.gamma == 1.0
            && customTargetSize == nil
            && !ImageProcessor.isWideColor(image) {
            return image
        }
        
        var workingImage = image
        
        // 1. Bake orientation upright before vImage/CoreImage processing
        if workingImage.imageOrientation != .up {
            if let fixed = fixOrientation(of: workingImage) {
                workingImage = fixed
            }
        }
        
        // 2. Smart Crop Margins (Trims white space so downsampling maximizes artwork)
        if settings.trimMargins {
            if let cropRect = SmartCropper.suggestCrop(for: workingImage) {
                if let cropped = crop(image: workingImage, to: cropRect) {
                    workingImage = cropped
                }
            }
        }
        
        // 3. Moiré Reduction (Pre-scaling step: Gaussian Blur to remove halftone frequencies)
        if settings.imageEnhancement.reduceMoire {
            workingImage = applyMoireReduction(to: workingImage)
        }
        
        // 4. High-Performance aspect-fit scaling using Accelerate vImage
        if let targetSize = targetSizeToUse {
            let originalSize = workingImage.size
            if customTargetSize != nil || originalSize.width > targetSize.width || originalSize.height > targetSize.height {
                var safeTargetSize = targetSize
                // Dynamic Orientation-Aware Scaling
                if customTargetSize == nil && originalSize.width > originalSize.height {
                    safeTargetSize = CGSize(width: max(targetSize.width, targetSize.height), height: min(targetSize.width, targetSize.height))
                }
                if let scaled = resize(image: workingImage, toFit: safeTargetSize) {
                    workingImage = scaled
                }
            }
        }
        
        // 5. Asymmetric Binding Margins (Gutter Space)
        if settings.bindingMarginOffset > 0 && settings.bindingMarginSide != .none {
            workingImage = applyBindingMargin(to: workingImage, offset: CGFloat(settings.bindingMarginOffset), side: settings.bindingMarginSide, isOddPage: isOddPage)
        }
        
        // 6. CoreImage Unified Filtering (Brightness, Contrast, Sharpness, Grayscale, Dithering)
        workingImage = applyFilters(to: workingImage, settings: settings)
        
        // 🚨 ENFORCE sRGB Color Space. Wide-color (P3) JPEGs will hard-brick Kindle E-Ink screens.
        if ImageProcessor.isWideColor(workingImage) {
            workingImage = ImageProcessor.convertToSRGB(workingImage)
        }
        
        return workingImage
    }
    
    // Legacy compatibility wrapper
    func processImage(
        _ image: UIImage,
        for profile: TargetDeviceProfile,
        applyGrayscale: Bool,
        cropMargins: Bool = false,
        reduceMoire: Bool = false,
        dither: Bool = false,
        marginOffset: Int = 0,
        marginSide: BindingMarginSide = .none,
        isOddPage: Bool = true,
        customTargetSize: CGSize? = nil
    ) -> UIImage {
        var settings = ConversionSettings()
        settings.targetDeviceProfile = profile
        settings.imageEnhancement.grayscale = applyGrayscale
        settings.trimMargins = cropMargins
        settings.imageEnhancement.reduceMoire = reduceMoire
        settings.imageEnhancement.ditheringEnabled = dither
        settings.bindingMarginOffset = marginOffset
        settings.bindingMarginSide = marginSide
        return processImage(
            image,
            settings: settings,
            isOddPage: isOddPage,
            customTargetSize: customTargetSize
        )
    }
    
    // MARK: - Private Pipeline Stages
    
    /// Bakes image orientation into pixel buffers
    private func fixOrientation(of image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard // Forces standard sRGB color space
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(at: .zero) }
    }
    
    /// Crop to specific bounding box
    private func crop(image: UIImage, to rect: CGRect) -> UIImage? {
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
    
    /// Pre-scaling slight blur to eliminate high-frequency screentone matrices
    private func applyMoireReduction(to image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(1.0, forKey: kCIInputRadiusKey) // Very slight blur
        
        guard let output = blurFilter.outputImage, let finalCG = context.createCGImage(output, from: ciImage.extent) else { return image }
        return UIImage(cgImage: finalCG)
    }
    
    /// High-performance resizing using Accelerate vImage with guaranteed UIGraphics fallback
    private func resize(image: UIImage, toFit targetSize: CGSize) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        
        let widthRatio = targetSize.width / CGFloat(cgImage.width)
        let heightRatio = targetSize.height / CGFloat(cgImage.height)
        let scaleFactor = min(widthRatio, heightRatio)
        
        if scaleFactor >= 1.0 { return image }
        
        let newWidth = max(1, Int(CGFloat(cgImage.width) * scaleFactor))
        let newHeight = max(1, Int(CGFloat(cgImage.height) * scaleFactor))
        
        // 1. Try Accelerate vImage with dynamic image format detection (works on any pixel layout)
        if var format = vImage_CGImageFormat(cgImage: cgImage) {
            var sourceBuffer = vImage_Buffer()
            var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
            if error == kvImageNoError {
                defer { free(sourceBuffer.data) }
                var destinationBuffer = vImage_Buffer()
                error = vImageBuffer_Init(&destinationBuffer, vImagePixelCount(newHeight), vImagePixelCount(newWidth), format.bitsPerPixel, vImage_Flags(kvImageNoFlags))
                if error == kvImageNoError {
                    defer { free(destinationBuffer.data) }
                    error = vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
                    if error == kvImageNoError {
                        let resizedCGImage = vImageCreateCGImageFromBuffer(&destinationBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
                        if error == kvImageNoError, let result = resizedCGImage {
                            return UIImage(cgImage: result.takeRetainedValue())
                        }
                    }
                }
            }
        }
        
        // 2. Guaranteed UIGraphics fallback — 100% fail-safe for all JPEG/PNG/sRGB pixel layouts
        let renderFormat = UIGraphicsImageRendererFormat.default()
        renderFormat.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newWidth, height: newHeight), format: renderFormat)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        }
    }
    
    /// Pads the image with white space on the specified side
    private func applyBindingMargin(to image: UIImage, offset: CGFloat, side: BindingMarginSide, isOddPage: Bool) -> UIImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0,
              !originalSize.width.isNaN, !originalSize.height.isNaN,
              offset > 0, !offset.isNaN else {
            return image
        }
        let newWidth = originalSize.width + offset
        let newSize = CGSize(width: newWidth, height: originalSize.height)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard // Forces standard sRGB color space
        
        var drawX: CGFloat = 0
        
        switch side {
        case .left:
            drawX = offset
        case .right:
            drawX = 0
        case .alternating:
            drawX = isOddPage ? offset : 0
        case .none:
            return image
        }
        
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(x: drawX, y: 0, width: originalSize.width, height: originalSize.height))
        }
    }
    
    /// Unified filter pipeline applying contrast, brightness, gamma, sharpen, and dithering
    private func applyFilters(to image: UIImage, settings: ConversionSettings) -> UIImage {
        let grayscale = settings.imageEnhancement.grayscale
        let invert = settings.imageEnhancement.invertColors
        let autoContrast = settings.imageEnhancement.autoContrast
        let brightness = settings.imageEnhancement.brightness
        let vibrance = settings.imageEnhancement.vibrance
        let gamma = settings.imageEnhancement.gamma
        let sharpness = settings.imageEnhancement.sharpness
        let dither = settings.imageEnhancement.ditheringEnabled
        
        var processedImage = image
        
        // 1. Histogram Stretching (Auto Contrast) via vImage
        if autoContrast {
            if let stretched = applyHistogramStretch(image: processedImage) {
                processedImage = stretched
            }
        }
        
        guard let cgImage = processedImage.cgImage else {
            return processedImage
        }
        
        var currentCIImage = CIImage(cgImage: cgImage)
        
        // 2. Color Inversion
        if invert {
            if let invertFilter = CIFilter(name: "CIColorInvert") {
                invertFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
                if let out = invertFilter.outputImage {
                    currentCIImage = out
                }
            }
        }
        
        // 3. Brightness, Saturation/Vibrance (and general Grayscale)
        let targetSaturation = grayscale ? 0.0 : (1.0 + vibrance)
        if brightness != 0.0 || targetSaturation != 1.0 {
            if let colorFilter = CIFilter(name: "CIColorControls") {
                colorFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
                colorFilter.setValue(brightness, forKey: kCIInputBrightnessKey)
                colorFilter.setValue(targetSaturation, forKey: kCIInputSaturationKey)
                if grayscale && !autoContrast {
                    // Default E-Ink contrast boost (15%) to prevent washed out text
                    colorFilter.setValue(1.15, forKey: kCIInputContrastKey)
                }
                if let out = colorFilter.outputImage {
                    currentCIImage = out
                }
            }
        } else if grayscale {
            // Apply standard contrast boost for grayscale if contrast is not stretched
            if let colorFilter = CIFilter(name: "CIColorControls") {
                colorFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
                colorFilter.setValue(0.0, forKey: kCIInputSaturationKey)
                if !autoContrast {
                    colorFilter.setValue(1.15, forKey: kCIInputContrastKey)
                }
                if let out = colorFilter.outputImage {
                    currentCIImage = out
                }
            }
        }
        
        // 4. Gamma Correction
        if gamma != 1.0 {
            if let gammaFilter = CIFilter(name: "CIGammaAdjust") {
                gammaFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
                gammaFilter.setValue(gamma, forKey: "inputPower")
                if let out = gammaFilter.outputImage {
                    currentCIImage = out
                }
            }
        }
        
        // 5. Sharpening
        if sharpness > 0.0 {
            if let sharpenFilter = CIFilter(name: "CIUnsharpMask") {
                sharpenFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
                sharpenFilter.setValue(2.5, forKey: kCIInputRadiusKey)
                sharpenFilter.setValue(sharpness * 2.0, forKey: kCIInputIntensityKey)
                if let out = sharpenFilter.outputImage {
                    currentCIImage = out
                }
            }
        } else if settings.imageEnhancement.reduceMoire {
            // Post-moire reduction sharpening
            if let sharpenFilter = CIFilter(name: "CIUnsharpMask") {
                sharpenFilter.setValue(currentCIImage, forKey: kCIInputImageKey)
                sharpenFilter.setValue(1.5, forKey: kCIInputRadiusKey)
                sharpenFilter.setValue(0.5, forKey: kCIInputIntensityKey)
                if let out = sharpenFilter.outputImage {
                    currentCIImage = out
                }
            }
        }
        
        guard var finalCGImage = context.createCGImage(currentCIImage, from: currentCIImage.extent) else {
            return processedImage
        }
        
        if dither {
            if let dithered = applyFloydSteinbergDithering(to: finalCGImage) {
                finalCGImage = dithered
            }
        }
        
        return UIImage(cgImage: finalCGImage)
    }
    
    /// Contrast stretching via vImage
    private func applyHistogramStretch(image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
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
        
        error = vImageContrastStretch_ARGB8888(&sourceBuffer, &destBuffer, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        
        let resultCGImage = vImageCreateCGImageFromBuffer(&destBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
        guard error == kvImageNoError, let result = resultCGImage else { return nil }
        
        return UIImage(cgImage: result.takeRetainedValue())
    }

    /// Floyd-Steinberg error diffusion dithering for smooth 16-level E-Ink grayscale transitions.
    private func applyFloydSteinbergDithering(to cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = 1
        let bytesPerRow = width * bytesPerPixel
        
        // Pass nil to data to let CGContext allocate and own the memory safely
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let rawPointer = context.data else { return nil }
        let rawBytes = rawPointer.assumingMemoryBound(to: UInt8.self)
        
        // Error buffer to store distributed errors
        var errors = [Float](repeating: 0.0, count: width * height)
        
        for y in 0..<height {
            let rowOffset = y * width
            let nextRowOffset = (y + 1) * width
            let hasNextRow = (y + 1) < height
            
            for x in 0..<width {
                let idx = rowOffset + x
                let oldVal = Float(rawBytes[idx]) + errors[idx]
                
                // Clamp error-corrected value to valid range
                let clampedOldVal = max(0.0, min(255.0, oldVal))
                
                // Quantize to nearest of 16 gray levels (each level is spaced by 17: 0, 17, 34, ..., 255)
                let newVal = round(clampedOldVal / 17.0) * 17.0
                let quantizedVal = UInt8(max(0.0, min(255.0, newVal)))
                
                rawBytes[idx] = quantizedVal
                let error = clampedOldVal - newVal
                
                // Distribute errors using standard Floyd-Steinberg weights
                if x + 1 < width {
                    errors[idx + 1] += error * 7.0 / 16.0
                }
                if hasNextRow {
                    if x > 0 {
                        errors[nextRowOffset + (x - 1)] += error * 3.0 / 16.0
                    }
                    errors[nextRowOffset + x] += error * 5.0 / 16.0
                    if x + 1 < width {
                        errors[nextRowOffset + (x + 1)] += error * 1.0 / 16.0
                    }
                }
            }
        }
        
        return context.makeImage()
    }
}
