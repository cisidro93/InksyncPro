import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

class DeepScanPanelProvider: PanelProvider {
    
    func detectPanels(in image: UIImage, context: CIContext) async -> [PanelCandidate] {
        guard let cgImage = image.cgImage else { return [] }
        
        // 1. Preprocess: High Contrast Grayscale + Edge Detection
        // Goal: Turn "Content" into white blobs and "Gutters" into black lines (or vice versa).
        
        let ciImage = CIImage(cgImage: cgImage)
        
        // A. Grayscale
        let gray = ciImage.applyingFilter("CIPhotoEffectMono")
        
        // B. Edge Detection / Sobel (To find boundaries)
        // Alternatively: Thresholding.
        // Let's try Thresholding for "content vs gutter".
        // Gutters are usually white. Content is dark/mixed.
        
        // Invert so Gutters (White) become Black (0). Content becomes bright.
        let inverted = gray.applyingFilter("CIColorInvert")
        
        // Threshold: Everything below 0.1 (originally very bright white) becomes 0.
        // Everything else (content) becomes 1.
        // CoreImage doesn't have a simple "Threshold" filter that outputs binary mask easily without custom kernel.
        // We will do a "posterize" or "maximum component" approach.
        
        // Workaround: Use CIColorControls to max contrast.
        let contrast = inverted.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 10.0, // Extreme contrast
            kCIInputBrightnessKey: -0.5 // Push darker grays to black
        ])
        
        // 2. Render to Bitmap for Analysis
        // We need to scan the pixels to find bounding boxes of the "white" (content) regions.
        guard let outputCG = context.createCGImage(contrast, from: contrast.extent) else { return [] }
        
        return await scanForIslands(in: outputCG)
    }
    
    // Manual "Connected Components" Approximation
    private func scanForIslands(in cgImage: CGImage) async -> [PanelCandidate] {
        let width = cgImage.width
        let height = cgImage.height
        
        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }
        
        let bytesPerRow = cgImage.bytesPerRow
        let safeWidth = CGFloat(width)
        let safeHeight = CGFloat(height)
        
        // Scan for "Content Rows" and "Content Columns" to find rough grid
        // This is a "Projection Profile" method, effective for Manhattan layouts.
        // For irregular layouts, we really want a flood fill, but that's expensive in Swift loop.
        // We'll stick to Projection Profile for "Deep Scan" v1 as it covers 90% of failures (gutters not detected).
        
        // 1. Horizontal Projection (Find Y-ranges of content)
        var hasContentRow = [Bool](repeating: false, count: height)
        let threshold: UInt8 = 50 // Pixel intensity > 50 considered content
        
        // Optimization: Sample every 5th column
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 5) {
                let offset = y * bytesPerRow + x * 4 // Assuming RGBA/RGB
                let val = ptr[offset] // Red component (GS)
                if val > threshold {
                    hasContentRow[y] = true
                    break
                }
            }
        }
        
        // 2. Extract Y-Segments
        var ySegments: [(start: Int, end: Int)] = []
        var inSegment = false
        var startY = 0
        
        for y in 0..<height {
            if hasContentRow[y] {
                if !inSegment {
                    inSegment = true
                    startY = y
                }
            } else {
                if inSegment {
                    inSegment = false
                    // Filter noise (tiny rows)
                    if (y - startY) > (height / 50) {
                        ySegments.append((startY, y))
                    }
                }
            }
        }
        if inSegment { ySegments.append((startY, height)) }
        
        // 3. For each Y-Segment, Vertical Projection (Find X-ranges)
        var candidates: [PanelCandidate] = []
        
        for segment in ySegments {
            var hasContentCol = [Bool](repeating: false, count: width)
            
            // Optimization: Sample every 2nd row in this segment
            for x in 0..<width {
                for y in stride(from: segment.start, to: segment.end, by: 2) {
                    let offset = y * bytesPerRow + x * 4
                    let val = ptr[offset]
                    if val > threshold {
                        hasContentCol[x] = true
                        break
                    }
                }
            }
            
            var xSegments: [(start: Int, end: Int)] = []
            var inColSegment = false
            var startX = 0
            
            for x in 0..<width {
                if hasContentCol[x] {
                    if !inColSegment {
                        inColSegment = true
                        startX = x
                    }
                } else {
                    if inColSegment {
                        inColSegment = false
                        if (x - startX) > (width / 50) {
                            xSegments.append((startX, x))
                        }
                    }
                }
            }
            if inColSegment { xSegments.append((startX, width)) }
            
            // Create Shells
            for xSeg in xSegments {
                let rect = CGRect(
                    x: CGFloat(xSeg.start) / safeWidth,
                    y: CGFloat(1.0) - (CGFloat(segment.end) / safeHeight), // Vision Origin (Bottom-Left) Logic? 
                                                                         // NO. CGImage standard is Top-Left. 
                                                                         // But our Panel model matches Vision?
                                                                         // Vision: (0,0) is Bottom-Left. 
                                                                         // UIKit/CGImage: (0,0) is Top-Left.
                                                                         // We must convert.
                                                                         
                    // Standard Top-Left Rect first
                    width: CGFloat(xSeg.end - xSeg.start) / safeWidth,
                    height: CGFloat(segment.end - segment.start) / safeHeight
                )
                
                // Convert Top-Left to Bottom-Left (Vision)
                let visionRect = CGRect(
                    x: rect.minX,
                    y: 1.0 - rect.maxY, // Flip Y
                    width: rect.width,
                    height: rect.height
                )
                
                candidates.append(PanelCandidate(
                    boundingBox: visionRect,
                    confidence: 0.7, // Lower than Vision
                    method: .deepScanContour
                ))
            }
        }
        
        return candidates
    }
}
