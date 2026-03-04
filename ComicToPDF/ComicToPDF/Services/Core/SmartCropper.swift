import UIKit
import Accelerate

/// specialized service for detecting and removing solid-color margins from images
/// Uses vImage (Accelerate) for high-performance pixel analysis.
struct SmartCropper {
    
    /// Suggests a crop rectangle to remove margins.
    /// - Parameters:
    ///   - image: The source UIImage.
    ///   - sensitivity: Tolerance for color difference (0.0 - 1.0). Default 0.05 (5%).
    ///   - safetyPadding: Percentage of width/height to add back as padding. Default 0.01 (1%).
    /// - Returns: A CGRect in normalized coordinates (0-1) representing the crop, or nil if no crop needed.
    static func suggestCrop(for image: UIImage, sensitivity: Float = 0.05, safetyPadding: Float = 0.015) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        
        // 1. Convert to Grayscale for Analysis (Performance)
        // We only care about luminance for margin detection usually (white/black borders)
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        var sourceBuffer = vImage_Buffer()
        let error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }
        
        let width = Int(sourceBuffer.width)
        let height = Int(sourceBuffer.height)
        let rowBytes = Int(sourceBuffer.rowBytes)
        let data = sourceBuffer.data.assumingMemoryBound(to: UInt8.self)
        
        // 2. Sample Edges to Determine "Background Color" (Inset by 10 pixels to avoid scanner artifacts)
        let insetX = min(10, width/10)
        let insetY = min(10, height/10)
        let tl = getPixelLuma(data: data, x: insetX, y: insetY, rowBytes: rowBytes)
        let tr = getPixelLuma(data: data, x: width-1-insetX, y: insetY, rowBytes: rowBytes)
        let bl = getPixelLuma(data: data, x: insetX, y: height-1-insetY, rowBytes: rowBytes)
        let br = getPixelLuma(data: data, x: width-1-insetX, y: height-1-insetY, rowBytes: rowBytes)
        
        // Check consistency (allow small variance)
        let threshold = Int(sensitivity * 255)
        
        // Logic: specific corner checks. If top corners match, we can crop top. 
        // We'll treat this as "Inset Scanning".
        // Instead of a global background color, we detect the "edge color" for each side independently.
        
        // 3. Scan Inwards
        var cropTop = 0
        var cropBottom = height
        var cropLeft = 0
        var cropRight = width
        
        // Scan Top (Reference: Top-Left pixel)
        // We scan row by row. If a row has significant deviation, we stop.
        // We check the middle 80% of the row to avoid noise at extreme corners? 
        // No, typically text bubbles might touch corners. We should check the whole row.
        
        // TOP SCAN
        let topRef = tl
        for y in 0..<height/3 { // Don't crop more than 33%
            if rowHasContent(data: data, y: y, width: width, rowBytes: rowBytes, refLuma: topRef, threshold: threshold) {
                cropTop = y
                break
            }
        }
        
        // BOTTOM SCAN
        let botRef = bl
        for y in stride(from: height-1, to: height - (height/3), by: -1) {
            if rowHasContent(data: data, y: y, width: width, rowBytes: rowBytes, refLuma: botRef, threshold: threshold) {
                cropBottom = y
                break
            }
        }
        
        // LEFT SCAN
        let leftRef = tl
        for x in 0..<width/3 {
            if colHasContent(data: data, x: x, height: height, rowBytes: rowBytes, refLuma: leftRef, threshold: threshold) {
                cropLeft = x
                break
            }
        }
        
        // RIGHT SCAN
        let rightRef = tr
        for x in stride(from: width-1, to: width - (width/3), by: -1) {
            if colHasContent(data: data, x: x, height: height, rowBytes: rowBytes, refLuma: rightRef, threshold: threshold) {
                cropRight = x
                break
            }
        }
        
        // 4. Validate Crop
        // If we didn't crop anything, return nil
        if cropTop == 0 && cropBottom == height && cropLeft == 0 && cropRight == width {
            return nil
        }
        
        // 5. Apply Safety Padding
        // E.g. 1% of dimension
        let padX = Int(Float(width) * safetyPadding)
        let padY = Int(Float(height) * safetyPadding)
        
        cropLeft = max(0, cropLeft - padX)
        cropTop = max(0, cropTop - padY)
        cropRight = min(width, cropRight + padX)
        cropBottom = min(height, cropBottom + padY)
        
        // Final Rect Construction
        let finalX = CGFloat(cropLeft) / CGFloat(width)
        let finalY = CGFloat(cropTop) / CGFloat(height)
        let finalW = CGFloat(cropRight - cropLeft) / CGFloat(width)
        let finalH = CGFloat(cropBottom - cropTop) / CGFloat(height)
        
        // Sanity Check: Don't crop if remaining area is too small (<50%)
        if finalW < 0.5 || finalH < 0.5 { return nil }
        
        return CGRect(x: finalX, y: finalY, width: finalW, height: finalH)
    }
    
    // MARK: - Pixel Helpers
    
    @inline(__always)
    private static func getPixelLuma(data: UnsafePointer<UInt8>, x: Int, y: Int, rowBytes: Int) -> Int {
        let offset = y * rowBytes + x * 4
        // Approximate luma
        let b = Int(data[offset])
        let g = Int(data[offset+1])
        let r = Int(data[offset+2])
        return (r + g + b) / 3
    }
    
    private static func rowHasContent(data: UnsafePointer<UInt8>, y: Int, width: Int, rowBytes: Int, refLuma: Int, threshold: Int) -> Bool {
        var noiseCount = 0
        let allowedNoise = Int(Float(width) * 0.01) // 1% tolerance
        // Sample every pixel for accurate thin border detection
        for x in 0..<width {
            let luma = getPixelLuma(data: data, x: x, y: y, rowBytes: rowBytes)
            if abs(luma - refLuma) > threshold {
               noiseCount += 1
               if noiseCount > allowedNoise {
                   return true
               }
            }
        }
        return false
    }
    
    private static func colHasContent(data: UnsafePointer<UInt8>, x: Int, height: Int, rowBytes: Int, refLuma: Int, threshold: Int) -> Bool {
        var noiseCount = 0
        let allowedNoise = Int(Float(height) * 0.01) // 1% tolerance
        // Sample every pixel
        for y in 0..<height {
            let luma = getPixelLuma(data: data, x: x, y: y, rowBytes: rowBytes)
            if abs(luma - refLuma) > threshold {
               noiseCount += 1
               if noiseCount > allowedNoise {
                   return true
               }
            }
        }
        return false
    }
}
