import UIKit
import Vision
import Accelerate

/// A Pro-Level specialized service for detecting and removing solid-color margins and scanner beds from images.
/// Uses Apple's Vision Document Segmentation to find the true bounds of the artwork, 
/// falling back to high-performance vImage pixel analysis if Vision doesn't find clear boundaries.
struct SmartCropper {
    
    /// Suggests a crop rectangle to remove margins.
    /// - Parameters:
    ///   - image: The source UIImage.
    ///   - safetyPadding: Percentage of width/height to add back as padding to avoid clipping art.
    /// - Returns: A CGRect in normalized coordinates (0-1) representing the crop, or nil if no crop needed.
    static func suggestCrop(for image: UIImage, safetyPadding: CGFloat = 0.01) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        
        // 1. Pro-Level Approach: Vision Document Segmentation
        // This is the same ML model Apple uses to crop receipts and documents, excellent for finding 
        // the true edge of a comic scan against a scanner bed or thick margin.
        if let visionCrop = performVisionDocumentScan(cgImage: cgImage, safetyPadding: safetyPadding) {
            // Only use the Vision crop if it actually removes a meaningful amount of border
            if visionCrop.width < 0.98 || visionCrop.height < 0.98 {
                return visionCrop
            }
        }
        
        // 2. Fallback Approach: vImage Edge Scanning
        // If Vision doesn't see a "document in a background", we fall back to scanning 
        // inwards for solid colors (white/black borders).
        return performVImageInwardScan(cgImage: cgImage, safetyPadding: safetyPadding)
    }
    
    private static func performVisionDocumentScan(cgImage: CGImage, safetyPadding: CGFloat) -> CGRect? {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        if #available(iOS 15.0, *) {
            let request = VNDetectDocumentSegmentationRequest()
            do {
                try requestHandler.perform([request])
                if let result = request.results?.first {
                    // Vision gives us a polygon of the document. We'll take its bounding box.
                    // The bounding box is in normalized coordinates (0-1), bottom-left origin.
                    // We must convert it to top-left origin for standard UIKit/CoreGraphics use
                    var visionBox = result.boundingBox
                    
                    // Convert bottom-left origin to top-left origin
                    visionBox.origin.y = 1.0 - visionBox.origin.y - visionBox.size.height
                    
                    // Add safety padding
                    var finalBox = visionBox.insetBy(dx: -safetyPadding, dy: -safetyPadding)
                    // Clamp to 0-1
                    finalBox = finalBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    
                    return finalBox
                }
            } catch {
                Logger.shared.log("SmartCropper: Vision document scan failed — \(error.localizedDescription)", category: "AI", type: .warning)
            }
        }
        return nil
    }
    
    // MARK: - Legacy High-Performance Inward Scan
    
    private static func performVImageInwardScan(cgImage: CGImage, safetyPadding: CGFloat, sensitivity: Float = 0.05) -> CGRect? {
        guard let workingImage = createLowResThumbnail(from: cgImage, maxDimension: 512) else { return nil }
        guard workingImage.width > 10 && workingImage.height > 10 else { return nil }
        
        // We only care about luminance for margin detection usually (white/black borders)
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent
        )
        
        var sourceBuffer = vImage_Buffer()
        let error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, workingImage, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }
        
        let width = Int(sourceBuffer.width)
        let height = Int(sourceBuffer.height)
        let rowBytes = Int(sourceBuffer.rowBytes)
        let data = sourceBuffer.data.assumingMemoryBound(to: UInt8.self)
        
        // Sample Edges to Determine "Background Color" (Inset by 10 pixels to avoid scanner artifacts)
        let insetX = min(10, width/10)
        let insetY = min(10, height/10)
        let tl = getPixelLuma(data: data, x: insetX, y: insetY, rowBytes: rowBytes)
        let tr = getPixelLuma(data: data, x: width-1-insetX, y: insetY, rowBytes: rowBytes)
        let bl = getPixelLuma(data: data, x: insetX, y: height-1-insetY, rowBytes: rowBytes)
        _ = getPixelLuma(data: data, x: width-1-insetX, y: height-1-insetY, rowBytes: rowBytes)
        
        let threshold = Int(sensitivity * 255)
        var cropTop = 0
        var cropBottom = height
        var cropLeft = 0
        var cropRight = width
        
        // Scanning Logic
        for y in 0..<height/3 {
            if rowHasContent(data: data, y: y, width: width, rowBytes: rowBytes, refLuma: tl, threshold: threshold) { cropTop = y; break }
        }
        for y in stride(from: height-1, to: height - (height/3), by: -1) {
            if rowHasContent(data: data, y: y, width: width, rowBytes: rowBytes, refLuma: bl, threshold: threshold) { cropBottom = y; break }
        }
        for x in 0..<width/3 {
            if colHasContent(data: data, x: x, height: height, rowBytes: rowBytes, refLuma: tl, threshold: threshold) { cropLeft = x; break }
        }
        for x in stride(from: width-1, to: width - (width/3), by: -1) {
            if colHasContent(data: data, x: x, height: height, rowBytes: rowBytes, refLuma: tr, threshold: threshold) { cropRight = x; break }
        }
        
        if cropTop == 0 && cropBottom == height && cropLeft == 0 && cropRight == width { return nil }
        
        // Apply Safety Padding
        let padX = Int(CGFloat(width) * safetyPadding)
        let padY = Int(CGFloat(height) * safetyPadding)
        
        cropLeft = max(0, cropLeft - padX)
        cropTop = max(0, cropTop - padY)
        cropRight = min(width, cropRight + padX)
        cropBottom = min(height, cropBottom + padY)
        
        let finalX = CGFloat(cropLeft) / CGFloat(width)
        let finalY = CGFloat(cropTop) / CGFloat(height)
        let finalW = CGFloat(cropRight - cropLeft) / CGFloat(width)
        let finalH = CGFloat(cropBottom - cropTop) / CGFloat(height)
        
        if finalW < 0.5 || finalH < 0.5 { return nil } // Sanity check
        
        return CGRect(x: finalX, y: finalY, width: finalW, height: finalH)
    }
    
    // MARK: - Pixel Helpers
    
    private static func createLowResThumbnail(from cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        if width <= maxDimension && height <= maxDimension { return cgImage }
        
        let ratio = maxDimension / max(width, height)
        let newWidth = Int(width * ratio)
        let newHeight = Int(height * ratio)
        
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB() else { return cgImage }
        guard let context = CGContext(data: nil,
                                      width: newWidth,
                                      height: newHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cgImage }
        
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
    
    @inline(__always)
    private static func getPixelLuma(data: UnsafePointer<UInt8>, x: Int, y: Int, rowBytes: Int) -> Int {
        let offset = y * rowBytes + x * 4
        let b = Int(data[offset])
        let g = Int(data[offset+1])
        let r = Int(data[offset+2])
        return (r + g + b) / 3
    }
    
    private static func rowHasContent(data: UnsafePointer<UInt8>, y: Int, width: Int, rowBytes: Int, refLuma: Int, threshold: Int) -> Bool {
        var noiseCount = 0
        let allowedNoise = Int(Float(width) * 0.01) // 1% tolerance
        for x in 0..<width {
            let luma = getPixelLuma(data: data, x: x, y: y, rowBytes: rowBytes)
            if abs(luma - refLuma) > threshold {
               noiseCount += 1
               if noiseCount > allowedNoise { return true }
            }
        }
        return false
    }
    
    private static func colHasContent(data: UnsafePointer<UInt8>, x: Int, height: Int, rowBytes: Int, refLuma: Int, threshold: Int) -> Bool {
        var noiseCount = 0
        let allowedNoise = Int(Float(height) * 0.01) // 1% tolerance
        for y in 0..<height {
            let luma = getPixelLuma(data: data, x: x, y: y, rowBytes: rowBytes)
            if abs(luma - refLuma) > threshold {
               noiseCount += 1
               if noiseCount > allowedNoise { return true }
            }
        }
        return false
    }
}

