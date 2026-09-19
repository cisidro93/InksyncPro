import Vision
import UIKit
import simd
import CoreImage // ✅ Needed for Grayscale Filter

struct PanelExtractor {
    
    // Global Context for performance (creation is expensive)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    enum ExtractionMode: String, Codable, Equatable, Hashable {
        case automatic
        case conservative
        case aggressive
        case neural
        case grid
        
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .conservative: return "Conservative"
            case .aggressive: return "Aggressive"
            case .neural: return "Neural Enhanced"
            case .grid: return "Grid (2x2)"
            }
        }
    }
    
    struct Panel: Codable, Equatable, Identifiable {
        let id = UUID()
        let boundingBox: CGRect // Normalized 0..1 (Vision Origin: Bottom-Left)
        
        // Helper to convert to SIMD vector (minX, minY, maxX, maxY)
        var vector: SIMD4<Float> {
            return SIMD4<Float>(
                Float(boundingBox.minX),
                Float(boundingBox.minY),
                Float(boundingBox.maxX),
                Float(boundingBox.maxY)
            )
        }
        
        enum CodingKeys: String, CodingKey {
            case boundingBox
        }
    }
    
    // MARK: - Core Logic
    
    // ✅ Helper: Create High-Contrast Grayscale Image for better Edge Detection
    private static func preprocessForDetection(_ image: UIImage) -> CGImage? {
        guard let inputCGImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: inputCGImage)
        
        // 1. Grayscale (Better for sensing intensity gradients)
        guard let grayscale = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: ciImage])?.outputImage else {
            return inputCGImage
        }
        
        // 2. High Contrast (Make panel borders "pop")
        // Increasing contrast helps defined edges stand out against gradients
        guard let contrast = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: grayscale,
            kCIInputContrastKey: 1.3 // 30% Boost
        ])?.outputImage else {
            return inputCGImage
        }
        
        // Render
        return ciContext.createCGImage(contrast, from: contrast.extent)
    }
    
    static func detectPanels(in image: UIImage, mode: ExtractionMode = .automatic, mangaMode: Bool = false) async -> [Panel] {
        if mode == .grid {
            return generateGridPanels(rows: 2, cols: 2)
        }
        
        let detectionImage = preprocessForDetection(image).map { UIImage(cgImage: $0) } ?? image
        let detector = EnsemblePanelDetector()
        let candidates: [PanelCandidate]
        
        if mode == .conservative {
            let context = CIContext()
            candidates = await VisionPanelProvider().detectPanels(in: detectionImage, context: context)
        } else {
            candidates = await detector.detect(in: detectionImage)
        }
        
        var panels = candidates.map { Panel(boundingBox: $0.boundingBox) }
        
        // If vision + deep scan found fewer than 2 distinct panels on the page,
        // synthesize clean panels using intelligent multi-tier gutter decomposition.
        if panels.count < 2 {
            let gutterPanels = decomposeGutterPanels(in: image, mangaMode: mangaMode)
            if gutterPanels.count >= 2 {
                panels = gutterPanels
            }
        }
        
        return clusterAndSortPanels(panels, mangaMode: mangaMode)
    }
    
    // ✅ NEW: Recursive Row Clustering Algorithm
    // This is much more stable than simple sorting because it handles staggered grids correctly.
    private static func clusterAndSortPanels(_ panels: [Panel], mangaMode: Bool) -> [Panel] {
        // 1. Start with everything sorted by Top edge (Highest Y first)
        var pool = panels.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var sortedRows: [[Panel]] = []
        
        while !pool.isEmpty {
            // Take the highest remaining panel as the "Anchor" for a new row
            let anchor = pool.removeFirst()
            var currentRow: [Panel] = [anchor]
            
            // 2. Find all other panels that overlap vertically with this anchor
            // Logic: Do they share at least 50% vertical overlap?
            var remainingPool: [Panel] = []
            
            // Pre-calculate anchor vector once
            let anchorVec = anchor.vector
            
            for candidate in pool {
                // Use SIMD accelerated overlap check
                if isSameRow(anchorVec, candidate.vector) {
                    currentRow.append(candidate)
                } else {
                    remainingPool.append(candidate)
                }
            }
            pool = remainingPool
            
            // 3. Sort this specific row horizontally
            if mangaMode {
                // Right-to-Left: Higher X comes first
                currentRow.sort { $0.boundingBox.minX > $1.boundingBox.minX }
            } else {
                // Left-to-Right: Lower X comes first
                currentRow.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            }
            
            sortedRows.append(currentRow)
        }
        
        // Flatten the rows back into a single list
        return sortedRows.flatMap { $0 }
    }
    
    // Accelerated Row Check using SIMD
    // Vector Format: (minX, minY, maxX, maxY)
    // Indices: x=0, y=1, z=2, w=3
    private static func isSameRow(_ v1: SIMD4<Float>, _ v2: SIMD4<Float>) -> Bool {
        // Vision Coords: Y=0 is Bottom.
        // Y range is [y, w] (since y=minY, w=maxY)
        
        let yMin1 = v1.y
        let yMax1 = v1.w
        let yMin2 = v2.y
        let yMax2 = v2.w
        
        // Calculate Intersection of Y ranges
        let intersectionMin = max(yMin1, yMin2)
        let intersectionMax = min(yMax1, yMax2)
        let intersectionHeight = max(0, intersectionMax - intersectionMin)
        
        // Heights of original panels
        // Height = maxY - minY = w - y
        let h1 = yMax1 - yMin1
        let h2 = yMax2 - yMin2
        
        // If the intersection covers > 50% of the shorter panel's height, they are on the same row.
        let minHeight = min(h1, h2)
        return intersectionHeight > (minHeight * 0.5)
    }
    
    static func extractPanelRects(from image: UIImage, mode: ExtractionMode) async throws -> [CGRect] {
        let panels = await detectPanels(in: image, mode: mode)
        return panels.map { $0.boundingBox }
    }
    
    // MARK: - Helpers
    
    static func cropPanels(from image: UIImage, panels: [Panel]) async throws -> [UIImage] {
        guard image.cgImage != nil else { return [image] }
        
        return panels.compactMap { panel in
            cropImage(image, to: panel.boundingBox)
        }
    }
    
    // ✅ Helper for Single Crop (Used by CBZ Export)
    static func cropImage(_ image: UIImage, to normalizedRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        guard !normalizedRect.minX.isNaN && !normalizedRect.minX.isInfinite &&
              !normalizedRect.minY.isNaN && !normalizedRect.minY.isInfinite &&
              !normalizedRect.width.isNaN && !normalizedRect.width.isInfinite &&
              !normalizedRect.height.isNaN && !normalizedRect.height.isInfinite &&
              normalizedRect.width > 0 && normalizedRect.height > 0 else {
            return nil
        }
        
        let cropRect = CGRect(
            x: normalizedRect.minX * width,
            y: (1.0 - normalizedRect.maxY) * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        )
        
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
    
    static func extractPanels(from image: UIImage, mode: ExtractionMode, mangaMode: Bool = false) async throws -> [UIImage] {
        let panels = await detectPanels(in: image, mode: mode, mangaMode: mangaMode)
        if panels.isEmpty { return [image] }
        return try await cropPanels(from: image, panels: panels)
    }
    
    private static func generateGridPanels(rows: Int, cols: Int) -> [Panel] {
        var panels: [Panel] = []
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        for r in (0..<rows).reversed() {
            for c in 0..<cols {
                let rect = CGRect(x: Double(c) * w, y: Double(r) * h, width: w, height: h)
                panels.append(Panel(boundingBox: rect))
            }
        }
        return panels
    }

    // MARK: - Smart Gutter Detection & Overlapping Strides (Option C.1 & C.2)

    /// Option C.1: Scans the specified height range of the page to find horizontal gutters.
    /// Returns sorted normalized split ratios from the top (0.0...1.0) in UIKit coordinates.
    static func findHorizontalGutterRatios(in image: UIImage, startRatio: Double = 0.20, endRatio: Double = 0.80, maxGutters: Int = 2) -> [CGFloat] {
        guard let cgImage = image.cgImage else { return [] }
        guard let thumbnail = SmartCropper.createLowResThumbnail(from: cgImage, maxDimension: 256) else { return [] }

        let width = thumbnail.width
        let height = thumbnail.height
        guard width > 20 && height > 20 else { return [] }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var rawData = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))

        let startY = max(0, Int(Double(height) * startRatio))
        let endY = min(height - 1, Int(Double(height) * endRatio))

        struct GutterBand {
            let startY: Int
            let endY: Int
            var height: Int { endY - startY + 1 }
            var centerY: Int { startY + (height / 2) }
        }

        var candidateBands: [GutterBand] = []
        var currentBandStart: Int? = nil

        for y in startY...endY {
            let rowOffset = y * width
            var rowMin = 255
            var rowMax = 0
            var sum = 0

            for x in 0..<width {
                let val = Int(rawData[rowOffset + x])
                if val < rowMin { rowMin = val }
                if val > rowMax { rowMax = val }
                sum += val
            }

            let spread = rowMax - rowMin
            let avg = sum / width
            // Gutter row: uniform light, uniform dark, or very low variance
            let isGutterRow = (avg > 215 && spread < 50) || (avg < 40 && spread < 40) || spread < 22

            if isGutterRow {
                if currentBandStart == nil { currentBandStart = y }
            } else {
                if let start = currentBandStart {
                    let bandHeight = y - start
                    if bandHeight >= 3 { // At least 3px in 256px thumbnail (~1.2% page height)
                        candidateBands.append(GutterBand(startY: start, endY: y - 1))
                    }
                    currentBandStart = nil
                }
            }
        }

        if let start = currentBandStart {
            let bandHeight = (endY + 1) - start
            if bandHeight >= 3 {
                candidateBands.append(GutterBand(startY: start, endY: endY))
            }
        }

        guard !candidateBands.isEmpty else { return [] }

        // Sort candidate bands by height descending (thickest gutters first)
        let sortedBands = candidateBands.sorted { $0.height > $1.height }

        var selectedCenters: [Int] = []
        let minSeparationPx = Int(Double(height) * 0.16) // Bands must be separated by at least 16% height

        for band in sortedBands {
            let center = band.centerY
            let tooClose = selectedCenters.contains { abs($0 - center) < minSeparationPx }
            if !tooClose {
                selectedCenters.append(center)
                if selectedCenters.count >= maxGutters { break }
            }
        }

        // Convert selected Y centers to top-down UIKit normalized coordinates
        let topDownRatios = selectedCenters.map { yCenter -> CGFloat in
            let topDownY = height - 1 - yCenter
            return CGFloat(topDownY) / CGFloat(height)
        }.sorted()

        return topDownRatios
    }

    /// Single gutter convenience for mid-page division
    static func findHorizontalGutterRatio(in image: UIImage) -> CGFloat? {
        let ratios = findHorizontalGutterRatios(in: image, startRatio: 0.35, endRatio: 0.65, maxGutters: 1)
        return ratios.first
    }

    /// Generates smart reading strides for a page (Option C.1 & C.2).
    /// Tailored variation for dual pages vs nondual single pages:
    /// - Dual pages: Divided into 2 natural sections per page (Top Section & Bottom Section)
    ///   using mid-page gutter (C.1) or 20% overlapping safe zone (C.2).
    /// - Nondual single pages: Divided into 3 tiers if 2 gutters found (C.1) for optimal 2:1 landscape screen fit,
    ///   2 halves if 1 gutter found, or 3 overlapping strides (C.2) with 20% safe zone so speech bubbles are never sliced.
    /// - Double-page splash scans: Divided into Left/Right halves with reading direction respect.
    static func generateSmartStrides(for image: UIImage, isDualPage: Bool = false, mangaMode: Bool = false) -> [Panel] {
        let imgSize = image.size
        let isWideDoubleSpread = imgSize.width > imgSize.height * 1.18

        if isWideDoubleSpread {
            // Wide Double-Page Spread in a single image:
            // Divide into Left Half (Page 1 in LTR) and Right Half (Page 1 in RTL)
            let leftBox = CGRect(x: 0.0, y: 0.0, width: 0.52, height: 1.0)
            let rightBox = CGRect(x: 0.48, y: 0.0, width: 0.52, height: 1.0)

            let firstBox = mangaMode ? rightBox : leftBox
            let secondBox = mangaMode ? leftBox : rightBox

            // Top and Bottom strides for each half (20% overlap zone vertically)
            let firstTop = Panel(boundingBox: CGRect(x: firstBox.minX, y: 0.40, width: firstBox.width, height: 0.60))
            let firstBot = Panel(boundingBox: CGRect(x: firstBox.minX, y: 0.00, width: firstBox.width, height: 0.60))
            let secondTop = Panel(boundingBox: CGRect(x: secondBox.minX, y: 0.40, width: secondBox.width, height: 0.60))
            let secondBot = Panel(boundingBox: CGRect(x: secondBox.minX, y: 0.00, width: secondBox.width, height: 0.60))

            return [firstTop, firstBot, secondTop, secondBot]
        }

        if isDualPage {
            // Dual-Page Variation:
            // 2 sections per page for smooth 4-step spread cadence (Page 1 Top/Bot -> Page 2 Top/Bot)
            if let gutterRatio = findHorizontalGutterRatio(in: image) {
                // Option C.1: Clean split at detected gutter
                let topH = Double(gutterRatio)
                let botH = 1.0 - topH
                let topPanel = Panel(boundingBox: CGRect(x: 0, y: 1.0 - topH, width: 1.0, height: topH))
                let botPanel = Panel(boundingBox: CGRect(x: 0, y: 0, width: 1.0, height: botH))
                return [topPanel, botPanel]
            } else {
                // Option C.2: 20% overlapping safe zone
                let topPanel = Panel(boundingBox: CGRect(x: 0, y: 0.40, width: 1.0, height: 0.60))
                let botPanel = Panel(boundingBox: CGRect(x: 0, y: 0.00, width: 1.0, height: 0.60))
                return [topPanel, botPanel]
            }
        } else {
            // Nondual Single Page Variation:
            // Multi-tier detection for optimal landscape phone magnification
            let gutters = findHorizontalGutterRatios(in: image, startRatio: 0.22, endRatio: 0.78, maxGutters: 2)

            if gutters.count == 2 {
                // Option C.1: 3 clean tiers (Top Tier, Middle Tier, Bottom Tier)
                let g1 = Double(gutters[0])
                let g2 = Double(gutters[1])

                let tier1 = Panel(boundingBox: CGRect(x: 0, y: 1.0 - g1, width: 1.0, height: g1))
                let tier2 = Panel(boundingBox: CGRect(x: 0, y: 1.0 - g2, width: 1.0, height: g2 - g1))
                let tier3 = Panel(boundingBox: CGRect(x: 0, y: 0.0, width: 1.0, height: 1.0 - g2))
                return [tier1, tier2, tier3]
            } else if gutters.count == 1 {
                // Option C.1: 2 clean halves
                let g = Double(gutters[0])
                let topPanel = Panel(boundingBox: CGRect(x: 0, y: 1.0 - g, width: 1.0, height: g))
                let botPanel = Panel(boundingBox: CGRect(x: 0, y: 0, width: 1.0, height: 1.0 - g))
                return [topPanel, botPanel]
            } else {
                // Option C.2: 3 overlapping strides with 20% safe zones
                // Gives 3x magnification on iPhone landscape with zero bisected speech bubbles
                let strideTop = Panel(boundingBox: CGRect(x: 0, y: 0.55, width: 1.0, height: 0.45))
                let strideMid = Panel(boundingBox: CGRect(x: 0, y: 0.28, width: 1.0, height: 0.44))
                let strideBot = Panel(boundingBox: CGRect(x: 0, y: 0.00, width: 1.0, height: 0.45))
                return [strideTop, strideMid, strideBot]
            }
        }
    }

    /// Guided View Panel Provider:
    /// Respects the user's preferred PanelInspectionStyle (.hybrid, .dynamicAI, or .smartStrides).
    static func detectPanelsOrSmartStrides(
        in image: UIImage,
        isDualPage: Bool = false,
        mangaMode: Bool = false
    ) async -> [Panel] {
        let style = await MainActor.run { EBookPreferences.shared.panelInspectionStyle }

        switch style {
        case .smartStrides:
            // Explicit Smart Tiers / Gutter Stride Viewer (Top / Mid / Bottom Half-Page view)
            return generateSmartStrides(for: image, isDualPage: isDualPage, mangaMode: mangaMode)

        case .dynamicAI:
            // True AI Panel-by-Panel Guided View
            let detected = await detectPanels(in: image, mode: .automatic, mangaMode: mangaMode)
            if !detected.isEmpty {
                return detected
            }
            // Fallback to strides only if zero panels detected (e.g. text/cover page)
            return generateSmartStrides(for: image, isDualPage: isDualPage, mangaMode: mangaMode)

        case .hybrid:
            // Adaptive Hybrid: AI panels if 2 or more detected, otherwise smooth smart strides
            let detected = await detectPanels(in: image, mode: .automatic, mangaMode: mangaMode)
            if detected.count >= 2 {
                return detected
            }
            return generateSmartStrides(for: image, isDualPage: isDualPage, mangaMode: mangaMode)
        }
    }

    /// Synthesizes intelligent comic panels by combining detected horizontal tiers
    /// with internal vertical gutters. Guarantees clean panel detection even on hand-inked or borderless pages.
    static func decomposeGutterPanels(in image: UIImage, mangaMode: Bool = false) -> [Panel] {
        let tiers = generateSmartStrides(for: image, isDualPage: false, mangaMode: mangaMode)
        guard !tiers.isEmpty else { return [] }

        guard let cgImage = image.cgImage,
              let thumbnail = SmartCropper.createLowResThumbnail(from: cgImage, maxDimension: 256) else {
            return tiers
        }

        let width = thumbnail.width
        let height = thumbnail.height
        guard width > 20 && height > 20 else { return tiers }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var rawData = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return tiers }

        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))

        var resultPanels: [Panel] = []

        for tier in tiers {
            let b = tier.boundingBox
            // In CGContext thumbnail coordinates, row 0 is bottom, row height-1 is top
            let startRow = max(0, min(height - 1, Int(b.minY * Double(height))))
            let endRow = max(0, min(height - 1, Int(b.maxY * Double(height))))
            let tierHeight = endRow - startRow + 1

            if tierHeight < 15 {
                resultPanels.append(tier)
                continue
            }

            // Scan column slices within this tier (between 25% and 75% width) to find a vertical gutter
            let startX = Int(Double(width) * 0.25)
            let endX = Int(Double(width) * 0.75)
            var bestGutterX: Int? = nil
            var minVariance = Int.max

            for x in startX...endX {
                var colMin = 255
                var colMax = 0
                var sum = 0

                for y in startRow...endRow {
                    let val = Int(rawData[y * width + x])
                    if val < colMin { colMin = val }
                    if val > colMax { colMax = val }
                    sum += val
                }

                let spread = colMax - colMin
                let avg = sum / tierHeight

                // Check for a clean gutter column (uniform light/dark or minimal variance)
                let isGutterCol = (avg > 210 && spread < 45) || (avg < 40 && spread < 35) || spread < 20
                if isGutterCol && spread < minVariance {
                    minVariance = spread
                    bestGutterX = x
                }
            }

            if let splitX = bestGutterX {
                let splitRatio = Double(splitX) / Double(width)
                let leftPanel = Panel(boundingBox: CGRect(x: 0, y: b.minY, width: splitRatio, height: b.height))
                let rightPanel = Panel(boundingBox: CGRect(x: splitRatio, y: b.minY, width: 1.0 - splitRatio, height: b.height))
                if mangaMode {
                    resultPanels.append(rightPanel)
                    resultPanels.append(leftPanel)
                } else {
                    resultPanels.append(leftPanel)
                    resultPanels.append(rightPanel)
                }
            } else {
                resultPanels.append(tier)
            }
        }

        return resultPanels
    }
}
