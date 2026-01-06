import UIKit
import CoreImage

struct ImageProcessor {
    
    // Process a single image based on settings
    static func process(imageURL: URL, settings: ConversionSettings) -> UIImage? {
        guard let image = UIImage(contentsOfFile: imageURL.path) else { return nil }
        
        var finalImage = image
        
        // 1. Resize if needed (Optimize for Device)
        if settings.optimizeForDevice {
            // Get target resolution (Default to Scribe if not found)
            let targetSize = settings.targetDevice.resolution
            finalImage = resize(image: finalImage, toFit: targetSize)
        }
        
        // 2. Apply Image Enhancements
        if settings.imageEnhancement.grayscale {
            finalImage = convertToGrayscale(image: finalImage)
        }
        
        if settings.imageEnhancement.autoContrast {
            finalImage = applyAutoContrast(image: finalImage)
        }
        
        return finalImage
    }
    
    // MARK: - Helper Functions
    
    private static func resize(image: UIImage, toFit targetSize: CGSize) -> UIImage {
        let widthRatio = targetSize.width / image.size.width
        let heightRatio = targetSize.height / image.size.height
        let scaleFactor = min(widthRatio, heightRatio)
        
        // Don't upscale small images
        if scaleFactor >= 1.0 { return image }
        
        let newSize = CGSize(width: image.size.width * scaleFactor, height: image.size.height * scaleFactor)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    private static func convertToGrayscale(image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIPhotoEffectMono")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        
        if let output = filter?.outputImage,
           let cgImage = CIContext().createCGImage(output, from: output.extent) {
            return UIImage(cgImage: cgImage)
        }
        return image
    }
    
    private static func applyAutoContrast(image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(1.1, forKey: kCIInputContrastKey) // Boost contrast slightly
        filter?.setValue(0.1, forKey: kCIInputBrightnessKey)
        
        if let output = filter?.outputImage,
           let cgImage = CIContext().createCGImage(output, from: output.extent) {
            return UIImage(cgImage: cgImage)
        }
        return image
    }
}
