import Foundation
import SwiftUI

// MARK: - Goodnotes-Style Vector Paper Template Renderer

/// High-performance mathematical vector renderer for digital notebook paper templates.
/// Generates crisp vector paths with zero bitmap blur on ProMotion 120Hz Retina displays.
public struct PaperTemplateRenderer: Sendable {
    
    public static let shared = PaperTemplateRenderer()
    
    public init() {}
    
    // MARK: - Cornell 3-Zone Metrics
    
    public struct CornellMetrics: Sendable {
        public let cueColumnWidth: CGFloat
        public let summarySectionHeight: CGFloat
        public let headerHeight: CGFloat
        public let lineSpacing: CGFloat
        
        public init(
            cueColumnWidth: CGFloat = 140.0,
            summarySectionHeight: CGFloat = 130.0,
            headerHeight: CGFloat = 50.0,
            lineSpacing: CGFloat = 26.0
        ) {
            self.cueColumnWidth = cueColumnWidth
            self.summarySectionHeight = summarySectionHeight
            self.headerHeight = headerHeight
            self.lineSpacing = lineSpacing
        }
    }
    
    // MARK: - Vector Path Generators
    
    /// Generates the vector path for Cornell 3-zone paper dividers.
    public func createCornellDividersPath(in size: CGSize, metrics: CornellMetrics = CornellMetrics()) -> Path {
        var path = Path()
        guard size.width > 0 && size.height > 0 else { return path }
        
        let cueX = min(metrics.cueColumnWidth, size.width * 0.38)
        let summaryY = max(0, size.height - metrics.summarySectionHeight)
        let headerY = metrics.headerHeight
        
        // 1. Top Header Divider (horizontal)
        path.move(to: CGPoint(x: 0, y: headerY))
        path.addLine(to: CGPoint(x: size.width, y: headerY))
        
        // 2. Vertical Cue Column Divider (from header down to summary section)
        path.move(to: CGPoint(x: cueX, y: headerY))
        path.addLine(to: CGPoint(x: cueX, y: summaryY))
        
        // 3. Bottom Summary Divider (horizontal)
        path.move(to: CGPoint(x: 0, y: summaryY))
        path.addLine(to: CGPoint(x: size.width, y: summaryY))
        
        return path
    }
    
    /// Generates horizontal ruled lines for Cornell or College Ruled templates.
    public func createRuledLinesPath(
        in size: CGSize,
        startY: CGFloat = 50.0,
        endY: CGFloat? = nil,
        spacing: CGFloat = 26.0
    ) -> Path {
        var path = Path()
        guard size.width > 0 && spacing > 0 else { return path }
        
        let bottomLimit = endY ?? size.height
        var currentY = startY + spacing
        
        while currentY < bottomLimit {
            path.move(to: CGPoint(x: 0, y: currentY))
            path.addLine(to: CGPoint(x: size.width, y: currentY))
            currentY += spacing
        }
        
        return path
    }
    
    /// Generates an Engineering Millimeter Grid path with minor and major lines.
    public func createEngineeringGridPaths(
        in size: CGSize,
        minorSpacing: CGFloat = 6.0,
        majorInterval: Int = 5
    ) -> (minor: Path, major: Path) {
        var minorPath = Path()
        var majorPath = Path()
        guard size.width > 0 && size.height > 0 && minorSpacing > 0 else {
            return (minorPath, majorPath)
        }
        
        // Vertical lines
        var colIndex = 0
        var currentX: CGFloat = 0.0
        while currentX <= size.width {
            let isMajor = (colIndex % majorInterval == 0)
            if isMajor {
                majorPath.move(to: CGPoint(x: currentX, y: 0))
                majorPath.addLine(to: CGPoint(x: currentX, y: size.height))
            } else {
                minorPath.move(to: CGPoint(x: currentX, y: 0))
                minorPath.addLine(to: CGPoint(x: currentX, y: size.height))
            }
            currentX += minorSpacing
            colIndex += 1
        }
        
        // Horizontal lines
        var rowIndex = 0
        var currentY: CGFloat = 0.0
        while currentY <= size.height {
            let isMajor = (rowIndex % majorInterval == 0)
            if isMajor {
                majorPath.move(to: CGPoint(x: 0, y: currentY))
                majorPath.addLine(to: CGPoint(x: size.width, y: currentY))
            } else {
                minorPath.move(to: CGPoint(x: 0, y: currentY))
                minorPath.addLine(to: CGPoint(x: size.width, y: currentY))
            }
            currentY += minorSpacing
            rowIndex += 1
        }
        
        return (minorPath, majorPath)
    }
    
    /// Generates a 60-degree Isometric 3D grid path.
    public func createIsometricGridPath(in size: CGSize, spacing: CGFloat = 24.0) -> Path {
        var path = Path()
        guard size.width > 0 && size.height > 0 && spacing > 0 else { return path }
        
        let dx = spacing * cos(.pi / 6) // spacing * sqrt(3) / 2
        let dy = spacing * 0.5
        
        // 1. Vertical lines
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += dx * 2
        }
        
        // 2. +30 degree diagonal lines
        let diagStep = dy * 2
        var yStart: CGFloat = -size.width * tan(.pi / 6)
        while yStart <= size.height {
            let start = CGPoint(x: 0, y: yStart)
            let end = CGPoint(x: size.width, y: yStart + size.width * tan(.pi / 6))
            path.move(to: start)
            path.addLine(to: end)
            yStart += diagStep
        }
        
        // 3. -30 degree diagonal lines
        yStart = 0
        let maxDiagY = size.height + size.width * tan(.pi / 6)
        while yStart <= maxDiagY {
            let start = CGPoint(x: 0, y: yStart)
            let end = CGPoint(x: size.width, y: yStart - size.width * tan(.pi / 6))
            path.move(to: start)
            path.addLine(to: end)
            yStart += diagStep
        }
        
        return path
    }
    
    /// Generates a Hexagonal honeycomb lattice path.
    public func createHexagonalGridPath(in size: CGSize, radius: CGFloat = 16.0) -> Path {
        var path = Path()
        guard size.width > 0 && size.height > 0 && radius > 0 else { return path }
        
        let hexWidth = sqrt(3.0) * radius
        let vertStep = 1.5 * radius
        let horizStep = hexWidth
        
        var row = 0
        var y: CGFloat = radius
        while y <= size.height + radius {
            let xOffset: CGFloat = (row % 2 == 1) ? (horizStep / 2) : 0
            var x: CGFloat = xOffset
            
            while x <= size.width + hexWidth {
                // Add a single hexagon
                drawHexagon(into: &path, center: CGPoint(x: x, y: y), radius: radius)
                x += horizStep
            }
            
            y += vertStep
            row += 1
        }
        
        return path
    }
    
    private func drawHexagon(into path: inout Path, center: CGPoint, radius: CGFloat) {
        for i in 0..<6 {
            let angle = CGFloat(i) * CGFloat.pi / 3.0 - CGFloat.pi / 6.0
            let pt = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if i == 0 {
                path.move(to: pt)
            } else {
                path.addLine(to: pt)
            }
        }
        path.closeSubpath()
    }
}
