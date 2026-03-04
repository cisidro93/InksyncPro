import UIKit
import Accelerate

struct ImageProcessor {
    
    // Process a single image based on settings
    static func process(imageURL: URL, settings: ConversionSettings) -> UIImage? {
        guard let image = UIImage(contentsOfFile: imageURL.path) else { return nil }
        
        var finalImage = image
        
        // 0. Smart Margin Removal (Full-Bleed) - ✅ NEW
        if settings.trimMargins {
            if let cropRect = SmartCropper.suggestCrop(for: finalImage) {
                // Apply the crop
                if let cropped = crop(image: finalImage, to: cropRect) {
                    finalImage = cropped
                }
            }
        }
        
        // 1. Resize if needed (Optimize for Device)
        if settings.optimizeForDevice {
            // Get target resolution (Default to Scribe if not found)
            let targetSize = settings.targetDevice.resolution
            // Use vImage for high-performance resizing
            if let resized = resize(image: finalImage, toFit: targetSize) {
                finalImage = resized
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
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return image }
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
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }
    
    private static func applyGamma(image: UIImage, gamma: Double) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIGammaAdjust")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(gamma, forKey: "inputPower")
        
        if let output = filter?.outputImage,
           let cgImage = CIContext().createCGImage(output, from: output.extent) {
            return UIImage(cgImage: cgImage)
        }
        return image
    }
}
