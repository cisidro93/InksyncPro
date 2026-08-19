import Foundation
import PDFKit
import CoreGraphics

// MARK: - PDF Column Models

/// Represents a single text column region detected on a PDF page.
public struct PDFColumn: Sendable, Identifiable, Equatable {
    public let id: Int
    public let rect: CGRect               // Bounding box in PDF page coordinates
    public let normalizedRect: CGRect     // Normalized (0...1) page coordinates
    
    public init(id: Int, rect: CGRect, normalizedRect: CGRect) {
        self.id = id
        self.rect = rect
        self.normalizedRect = normalizedRect
    }
}

/// Represents the analyzed column layout of a PDF page.
public struct PageColumnLayout: Sendable, Equatable {
    public let pageIndex: Int
    public let pageBounds: CGRect
    public let columns: [PDFColumn]
    
    public var isMultiColumn: Bool {
        columns.count > 1
    }
    
    public init(pageIndex: Int, pageBounds: CGRect, columns: [PDFColumn]) {
        self.pageIndex = pageIndex
        self.pageBounds = pageBounds
        self.columns = columns
    }
}

// MARK: - PDF Column Detector Actor

/// High-performance background actor analyzing PDF page layouts, detecting continuous vertical gutters,
/// and computing exact column bounding boxes for smart double-tap snapping.
public actor PDFColumnDetector {
    
    public static let shared = PDFColumnDetector()
    
    // In-memory cache for analyzed page layouts: [CacheKey: PageColumnLayout]
    private var layoutCache: [String: PageColumnLayout] = [:]
    
    public init() {}
    
    // MARK: - Public API
    
    /// Detects column boundaries for a given `PDFPage`.
    /// Offloads layout analysis from the main thread.
    public func detectColumns(in page: PDFPage, pageIndex: Int) -> PageColumnLayout {
        let cacheKey = "\(pageIndex)_\(page.bounds(for: .cropBox).integral)"
        if let cached = layoutCache[cacheKey] {
            return cached
        }
        
        let cropBox = page.bounds(for: .cropBox)
        guard cropBox.width > 50 && cropBox.height > 50 else {
            let singleCol = PDFColumn(id: 0, rect: cropBox, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            let defaultLayout = PageColumnLayout(pageIndex: pageIndex, pageBounds: cropBox, columns: [singleCol])
            return defaultLayout
        }
        
        // Extract text line rects from PDFPage
        let textRects = extractTextLineRects(from: page, in: cropBox)
        
        // If minimal text detected (e.g. scanned image/comic), fallback to single column
        if textRects.count < 6 {
            let singleCol = PDFColumn(id: 0, rect: cropBox, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            let defaultLayout = PageColumnLayout(pageIndex: pageIndex, pageBounds: cropBox, columns: [singleCol])
            layoutCache[cacheKey] = defaultLayout
            return defaultLayout
        }
        
        // Analyze vertical gutters across the horizontal axis
        let columns = analyzeGuttersAndClusterColumns(textRects: textRects, pageBounds: cropBox)
        
        let layout = PageColumnLayout(pageIndex: pageIndex, pageBounds: cropBox, columns: columns)
        layoutCache[cacheKey] = layout
        return layout
    }
    
    /// Finds the target column enclosing or closest to the given page coordinate point.
    public func findTargetColumn(at pointInPage: CGPoint, in layout: PageColumnLayout) -> PDFColumn? {
        guard !layout.columns.isEmpty else { return nil }
        
        // 1. Direct containment check
        if let direct = layout.columns.first(where: { $0.rect.contains(pointInPage) }) {
            return direct
        }
        
        // 2. Horizontal distance check (find closest column along X axis)
        var closestCol = layout.columns.first!
        var minDistance: CGFloat = .greatestFiniteMagnitude
        
        for col in layout.columns {
            let colMidX = col.rect.midX
            let dist = abs(pointInPage.x - colMidX)
            if dist < minDistance {
                minDistance = dist
                closestCol = col
            }
        }
        
        return closestCol
    }
    
    /// Clears the analyzed layout cache to release memory upon document dismissal.
    public func purgeCache() {
        layoutCache.removeAll()
    }
    
    // MARK: - Internal Analysis Algorithms
    
    private func extractTextLineRects(from page: PDFPage, in pageBounds: CGRect) -> [CGRect] {
        var rects: [CGRect] = []
        let charCount = page.numberOfCharacters
        guard charCount > 0 else { return [] }
        
        // Sample character boxes in steps to keep CPU overhead minimal (< 2ms per page)
        let sampleStep = max(1, charCount / 300)
        var idx = 0
        
        while idx < charCount {
            let charBounds = page.characterBounds(at: idx)
            if charBounds.width > 1 && charBounds.height > 1 && pageBounds.contains(charBounds.origin) {
                rects.append(charBounds)
            }
            idx += sampleStep
        }
        
        return rects
    }
    
    private func analyzeGuttersAndClusterColumns(textRects: [CGRect], pageBounds: CGRect) -> [PDFColumn] {
        let numBins = 100
        let binWidth = pageBounds.width / CGFloat(numBins)
        var binDensities = [Int](repeating: 0, count: numBins)
        
        // Build horizontal density histogram
        for rect in textRects {
            let relMinX = max(0, rect.minX - pageBounds.minX)
            let relMaxX = min(pageBounds.width, rect.maxX - pageBounds.minX)
            
            let startBin = max(0, min(numBins - 1, Int(relMinX / binWidth)))
            let endBin = max(0, min(numBins - 1, Int(relMaxX / binWidth)))
            
            for b in startBin...endBin {
                binDensities[b] += 1
            }
        }
        
        // Identify potential gutter valleys (low text density between page margins)
        // Skip page outer margins (first 10% and last 10%)
        let marginBins = numBins / 10
        var candidateGutterMids: [CGFloat] = []
        var currentGutterStart: Int? = nil
        let minGutterBins = max(2, Int(12.0 / binWidth)) // At least 12pt wide
        
        for b in marginBins..<(numBins - marginBins) {
            let density = binDensities[b]
            if density <= 1 {
                if currentGutterStart == nil {
                    currentGutterStart = b
                }
            } else {
                if let start = currentGutterStart {
                    let gutterLength = b - start
                    if gutterLength >= minGutterBins {
                        let midBin = CGFloat(start + b) / 2.0
                        let gutterX = pageBounds.minX + (midBin * binWidth)
                        candidateGutterMids.append(gutterX)
                    }
                    currentGutterStart = nil
                }
            }
        }
        
        // Filter gutters: only accept at most 2 major dividing gutters (supporting up to 3 columns)
        let validGutters = candidateGutterMids.prefix(2)
        
        if validGutters.isEmpty {
            // Single Column
            let singleCol = PDFColumn(id: 0, rect: pageBounds, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            return [singleCol]
        }
        
        // Build Column Rectangles divided by gutters
        var columns: [PDFColumn] = []
        var prevX = pageBounds.minX
        let padding: CGFloat = 8.0
        
        for (index, gutterX) in validGutters.enumerated() {
            let colRect = CGRect(
                x: max(pageBounds.minX, prevX - padding),
                y: pageBounds.minY,
                width: max(20, (gutterX - prevX) + (padding * 2)),
                height: pageBounds.height
            )
            let normRect = CGRect(
                x: (colRect.minX - pageBounds.minX) / pageBounds.width,
                y: (colRect.minY - pageBounds.minY) / pageBounds.height,
                width: colRect.width / pageBounds.width,
                height: colRect.height / pageBounds.height
            )
            columns.append(PDFColumn(id: index, rect: colRect, normalizedRect: normRect))
            prevX = gutterX
        }
        
        // Final column on the right
        let finalRect = CGRect(
            x: max(pageBounds.minX, prevX - padding),
            y: pageBounds.minY,
            width: max(20, pageBounds.maxX - prevX + padding),
            height: pageBounds.height
        )
        let finalNorm = CGRect(
            x: (finalRect.minX - pageBounds.minX) / pageBounds.width,
            y: (finalRect.minY - pageBounds.minY) / pageBounds.height,
            width: finalRect.width / pageBounds.width,
            height: finalRect.height / pageBounds.height
        )
        columns.append(PDFColumn(id: columns.count, rect: finalRect, normalizedRect: finalNorm))
        
        return columns
    }
}
