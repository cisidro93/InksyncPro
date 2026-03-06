import SwiftUI
import CoreGraphics

class CoverGenerator {
    
    /// Adds a professional, translucent "Part X of Y" badge to the top right of the provided cover image.
    /// - Parameters:
    ///   - originalData: The original image data (from the first page of the comic).
    ///   - partNumber: The current split part (e.g., 1 for "Part 1").
    ///   - totalParts: The total number of splits (e.g., 3 for "Part 1 of 3").
    /// - Returns: A new JPEG `Data` object containing the composited image, or the original if blending fails.
    static func generateCover(from originalData: Data, partNumber: Int, totalParts: Int) -> Data {
        guard let originalImage = UIImage(data: originalData) else {
            return originalData
        }
        
        // Define canvas scale based on the original image dimensions
        let size = originalImage.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = originalImage.scale
        
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        
        let finalImage = renderer.image { context in
            // 1. Draw the exact original cover first
            originalImage.draw(at: .zero)
            
            // 2. Define Badge Dimensions relative to cover size (roughly 25% of width, bounded)
            let badgeWidth = min(max(size.width * 0.25, 200), size.width * 0.45)
            let badgeHeight = badgeWidth * 0.25 // 4:1 aspect ratio for the pill
            let padding = badgeHeight * 0.5     // Distance from the top right edge
            
            let badgeRect = CGRect(
                x: size.width - badgeWidth - padding,
                y: padding,
                width: badgeWidth,
                height: badgeHeight
            )
            
            // 3. Draw the Glassmorphism Pill Background
            let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeHeight / 2.0)
            
            // Dark translucent base
            UIColor.black.withAlphaComponent(0.65).setFill()
            badgePath.fill()
            
            // Crisp 1px white border stroke for the "Pro Apple" feel
            UIColor.white.withAlphaComponent(0.85).setStroke()
            badgePath.lineWidth = max(size.width * 0.005, 1.5) // Scaling outline width
            badgePath.stroke()
            
            // 4. Draw the Text Layout ("Part X of Y")
            let badgeText = "Part \(partNumber) of \(totalParts)"
            
            // Calculate a dynamic font size that perfectly fits inside the pill
            let fontSize = badgeHeight * 0.45 
            let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
            
            // Add subtle drop shadow to text for maximum readability on any background
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = CGSize(width: 0, height: 2)
            
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .shadow: shadow
            ]
            
            let attributedString = NSAttributedString(string: badgeText, attributes: textAttributes)
            let textSize = attributedString.size()
            
            // Perfect Dead-Center Alignment inside the pill
            let textRect = CGRect(
                x: badgeRect.origin.x + (badgeWidth - textSize.width) / 2.0,
                y: badgeRect.origin.y + (badgeHeight - textSize.height) / 2.0,
                width: textSize.width,
                height: textSize.height
            )
            
            attributedString.draw(in: textRect)
        }
        
        // Return compressed JPEG of the new comp
        return finalImage.jpegData(compressionQuality: 0.9) ?? originalData
    }
}
