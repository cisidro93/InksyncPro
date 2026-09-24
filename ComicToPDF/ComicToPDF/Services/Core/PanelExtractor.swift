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
    
    // MARK: - Recursive Spatial Subdivision (Layout Tree / XY-Cut Reading Order)

    /// Sorts detected panels using Recursive Spatial Subdivision (Layout Tree / XY-Cut)
    /// with SIMD-accelerated row clustering fallback for staggered or interlocking grids.
    private static func clusterAndSortPanels(_ panels: [Panel], mangaMode: Bool) -> [Panel] {
        guard panels.count > 1 else { return panels }
        return recursiveXYCutSort(panels, mangaMode: mangaMode)
    }

    private static func recursiveXYCutSort(_ panels: [Panel], mangaMode: Bool) -> [Panel] {
        guard panels.count > 1 else { return panels }

        // 1. Horizontal Split (Top vs Bottom in Vision coords: Y=1 is Top, Y=0 is Bottom)
        let sortedY = panels.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        let tolerance: CGFloat = 0.015
        var minTopY = sortedY[0].boundingBox.minY
        for i in 0..<(sortedY.count - 1) {
            minTopY = min(minTopY, sortedY[i].boundingBox.minY)
            let remainingMaxY = sortedY[(i + 1)...].map { $0.boundingBox.maxY }.max() ?? 0.0
            if remainingMaxY <= (minTopY + tolerance) {
                let topSet = Array(sortedY[0...i])
                let bottomSet = Array(sortedY[(i + 1)...])
                return recursiveXYCutSort(topSet, mangaMode: mangaMode) + recursiveXYCutSort(bottomSet, mangaMode: mangaMode)
            }
        }

        // 2. Vertical Split (Left vs Right)
        let sortedX = panels.sorted { $0.boundingBox.maxX < $1.boundingBox.maxX }
        var maxLeftX = sortedX[0].boundingBox.maxX
        for i in 0..<(sortedX.count - 1) {
            maxLeftX = max(maxLeftX, sortedX[i].boundingBox.maxX)
            let remainingMinX = sortedX[(i + 1)...].map { $0.boundingBox.minX }.min() ?? 0.0
            if remainingMinX >= (maxLeftX - tolerance) {
                let leftSet = Array(sortedX[0...i])
                let rightSet = Array(sortedX[(i + 1)...])
                if mangaMode {
                    return recursiveXYCutSort(rightSet, mangaMode: mangaMode) + recursiveXYCutSort(leftSet, mangaMode: mangaMode)
                } else {
                    return recursiveXYCutSort(leftSet, mangaMode: mangaMode) + recursiveXYCutSort(rightSet, mangaMode: mangaMode)
                }
            }
        }

        // 3. Fallback: SIMD-accelerated vertical row clustering for complex staggered grids
        return clusterAndSortPanelsSIMD(panels, mangaMode: mangaMode)
    }

    private static func clusterAndSortPanelsSIMD(_ panels: [Panel], mangaMode: Bool) -> [Panel] {
        var pool = panels.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var sortedRows: [[Panel]] = []
        
        while !pool.isEmpty {
            let anchor = pool.removeFirst()
            var currentRow: [Panel] = [anchor]
            var remainingPool: [Panel] = []
            let anchorVec = anchor.vector
            
            for candidate in pool {
                if isSameRow(anchorVec, candidate.vector) {
                    currentRow.append(candidate)
                } else {
                    remainingPool.append(candidate)
                }
            }
            pool = remainingPool
            
            if mangaMode {
                currentRow.sort { $0.boundingBox.minX > $1.boundingBox.minX }
            } else {
                currentRow.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            }
            
            sortedRows.append(currentRow)
        }
        
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
    /// Generates smart reading strides for a comic page, respecting custom user configurations,
    /// tier counts (2, 3, 4), safe overlap zones (10% - 25%), column splits, and Manga RTL flow.
    static func generateSmartStrides(
        for image: UIImage,
        isDualPage: Bool = false,
        mangaMode: Bool = false,
        config: ComicTierGuideConfiguration? = nil
    ) -> [Panel] {
        let quads = generateComicQuadrants(
            for: image.size,
            isDualPage: isDualPage,
            mangaMode: mangaMode,
            config: config,
            imageForGutterAnalysis: image
        )
        return quads.map { Panel(boundingBox: $0.normalizedRect) }
    }

    /// Guided View Panel Provider:
    /// Strictly uses production-ready Smart Tiers (horizontal gutter & tier strides).
    static func detectPanelsOrSmartStrides(
        in image: UIImage,
        isDualPage: Bool = false,
        mangaMode: Bool = false,
        config: ComicTierGuideConfiguration? = nil
    ) async -> [Panel] {
        return generateSmartStrides(for: image, isDualPage: isDualPage, mangaMode: mangaMode, config: config)
    }

    /// Generates ordered ComicTierQuadrants with step ordering, labels, and normalized bounding boxes.
    static func generateComicQuadrants(
        for imageSize: CGSize,
        isDualPage: Bool = false,
        mangaMode: Bool = false,
        config: ComicTierGuideConfiguration? = nil,
        imageForGutterAnalysis: UIImage? = nil
    ) -> [ComicTierQuadrant] {
        let isWideDoubleSpread = imageSize.width > imageSize.height * 1.18

        // If the user has configured custom per-quadrant overrides in NeoFlow Studio, honor them directly
        let customOverrides: [Int: CGRect] = {
            if let jsonStr = UserDefaults.standard.string(forKey: "boox_customBlockOverridesJSON"),
               let data = jsonStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([Int: CGRect].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            return [:]
        }()

        let booxGridRaw = UserDefaults.standard.string(forKey: "boox_gridPreset") ?? ""
        let booxPreset = BooxGridPreset(rawValue: booxGridRaw)
        let isAdvancedBooxPreset = booxPreset == .twoByThree || booxPreset == .threeByTwo || booxPreset == .threeByThree || booxPreset == .oneOverTwo || booxPreset == .twoOverOne

        if config == nil && (!customOverrides.isEmpty || isAdvancedBooxPreset) {
            let booxFlowRaw = UserDefaults.standard.string(forKey: "boox_flowOrder") ?? BooxFlowOrder.reverseNFlow.rawValue
            let booxSpread = UserDefaults.standard.bool(forKey: "boox_isSpreadMode")
            let booxSplit = UserDefaults.standard.double(forKey: "boox_verticalSplitRatio") != 0 ? UserDefaults.standard.double(forKey: "boox_verticalSplitRatio") : 0.50
            let booxH0 = UserDefaults.standard.double(forKey: "boox_horizontalSplit0") != 0 ? UserDefaults.standard.double(forKey: "boox_horizontalSplit0") : 0.50
            let booxH1 = UserDefaults.standard.double(forKey: "boox_horizontalSplit1") != 0 ? UserDefaults.standard.double(forKey: "boox_horizontalSplit1") : 0.66
            let booxRedundancy = UserDefaults.standard.object(forKey: "boox_connectionRedundancy") != nil ? UserDefaults.standard.bool(forKey: "boox_connectionRedundancy") : true
            let booxRedRatio = UserDefaults.standard.double(forKey: "boox_redundancyRatio") != 0 ? UserDefaults.standard.double(forKey: "boox_redundancyRatio") : 0.15

            var effectiveFlow = BooxFlowOrder(rawValue: booxFlowRaw) ?? (mangaMode ? .reverseNFlow : .nFlow)
            if mangaMode {
                if effectiveFlow == .nFlow { effectiveFlow = .reverseNFlow }
                else if effectiveFlow == .zFlow { effectiveFlow = .reverseZFlow }
            }

            let booxConfig = BooxSectionFlowConfig(
                gridPreset: booxPreset ?? .twoByTwo,
                flowOrder: effectiveFlow,
                isSpreadMode: booxSpread || isWideDoubleSpread,
                verticalSplitRatio: CGFloat(booxSplit),
                horizontalSplitRatios: [CGFloat(booxH0), CGFloat(booxH1)],
                topMarginTrim: CGFloat(UserDefaults.standard.double(forKey: "boox_topMarginTrim")),
                bottomMarginTrim: CGFloat(UserDefaults.standard.double(forKey: "boox_bottomMarginTrim")),
                leftMarginTrim: CGFloat(UserDefaults.standard.double(forKey: "boox_leftMarginTrim")),
                rightMarginTrim: CGFloat(UserDefaults.standard.double(forKey: "boox_rightMarginTrim")),
                autoCropAfterPagination: UserDefaults.standard.bool(forKey: "boox_autoCropAfterPagination"),
                connectionRedundancy: booxRedundancy,
                redundancyRatio: CGFloat(booxRedRatio),
                customBlockOverrides: customOverrides
            )
            let booxBlocks = BooxSectionFlowEngine.shared.generateBlocks(config: booxConfig, space: .pdf)
            if !booxBlocks.isEmpty {
                return booxBlocks.map { b in
                    ComicTierQuadrant(
                        id: b.id,
                        columnIndex: b.columnIndex,
                        tierIndex: b.rowIndex,
                        totalColumns: booxConfig.gridPreset.columnCount,
                        totalTiersInColumn: booxConfig.gridPreset.rowCount,
                        stepOrder: b.stepOrder,
                        totalInPage: b.totalBlocks,
                        normalizedRect: booxConfig.connectionRedundancy ? b.redundantRect : b.normalizedRect,
                        label: b.label
                    )
                }
            }
        }

        let activeConfig: ComicTierGuideConfiguration = {
            if let config = config {
                return config
            }
            let presetRaw = UserDefaults.standard.string(forKey: "comic_smartTierPreset") ?? ComicTierLayoutPreset.threeTier.rawValue
            let tierCount = UserDefaults.standard.integer(forKey: "comic_smartTierCount") != 0 ? UserDefaults.standard.integer(forKey: "comic_smartTierCount") : 3
            let columnCount = UserDefaults.standard.integer(forKey: "comic_smartTierColumnCount") != 0 ? UserDefaults.standard.integer(forKey: "comic_smartTierColumnCount") : 1
            let overlap = UserDefaults.standard.double(forKey: "comic_smartTierOverlap") != 0 ? UserDefaults.standard.double(forKey: "comic_smartTierOverlap") : 0.15
            let splitRatio = UserDefaults.standard.double(forKey: "comic_smartTierColumnSplitRatio") != 0 ? UserDefaults.standard.double(forKey: "comic_smartTierColumnSplitRatio") : 0.50
            let topTrim = UserDefaults.standard.double(forKey: "comic_smartTierTopMarginTrim")
            let bottomTrim = UserDefaults.standard.double(forKey: "comic_smartTierBottomMarginTrim")
            let leftTrim = UserDefaults.standard.double(forKey: "comic_smartTierLeftTrim")
            let rightTrim = UserDefaults.standard.double(forKey: "comic_smartTierRightTrim")
            let flowOrderRaw = UserDefaults.standard.string(forKey: "comic_smartTierFlowOrder") ?? (mangaMode ? ComicReadingFlowOrder.mangaRTL.rawValue : ComicReadingFlowOrder.columnFirst.rawValue)
            return ComicTierGuideConfiguration(
                preset: ComicTierLayoutPreset(rawValue: presetRaw) ?? .threeTier,
                tierCount: tierCount,
                columnCount: columnCount,
                overlap: overlap,
                columnSplitRatio: splitRatio,
                topMarginTrim: topTrim,
                bottomMarginTrim: bottomTrim,
                leftMarginTrim: leftTrim,
                rightMarginTrim: rightTrim,
                flowOrder: ComicReadingFlowOrder(rawValue: flowOrderRaw) ?? (mangaMode ? .mangaRTL : .columnFirst)
            )
        }()

        let leftTrim = max(0.0, min(0.25, CGFloat(activeConfig.leftMarginTrim)))
        let rightTrim = max(0.0, min(0.25, CGFloat(activeConfig.rightMarginTrim)))
        let activeW = max(0.2, 1.0 - (leftTrim + rightTrim))
        let effectiveRTL = mangaMode || activeConfig.flowOrder == .mangaRTL

        if isWideDoubleSpread {
            // Wide Double-Page Spread in a single image:
            // Divide into Left Half and Right Half
            let halfW = activeW / 2.0
            let leftBox = CGRect(x: leftTrim, y: 0.0, width: halfW, height: 1.0)
            let rightBox = CGRect(x: leftTrim + halfW, y: 0.0, width: halfW, height: 1.0)

            let cols = effectiveRTL ? [rightBox, leftBox] : [leftBox, rightBox]
            let colNames = effectiveRTL ? ["Right Page", "Left Page"] : ["Left Page", "Right Page"]

            let tiersCount = max(2, min(4, activeConfig.tierCount))
            var quads: [ComicTierQuadrant] = []
            var step = 0
            let totalSteps = tiersCount * 2

            if activeConfig.flowOrder == .rowFirst {
                for t in 0..<tiersCount {
                    for (cIdx, col) in cols.enumerated() {
                        let rect = computeTierRect(tierIndex: t, totalTiers: tiersCount, columnX: col.minX, columnW: col.width, config: activeConfig)
                        let lbl = "\(colNames[cIdx]) · \(tierSubLabel(index: t, total: tiersCount)) (\(step + 1)/\(totalSteps))"
                        quads.append(ComicTierQuadrant(
                            id: step,
                            columnIndex: cIdx,
                            tierIndex: t,
                            totalColumns: 2,
                            totalTiersInColumn: tiersCount,
                            stepOrder: step,
                            totalInPage: totalSteps,
                            normalizedRect: rect,
                            label: lbl
                        ))
                        step += 1
                    }
                }
            } else {
                for (cIdx, col) in cols.enumerated() {
                    for t in 0..<tiersCount {
                        let rect = computeTierRect(tierIndex: t, totalTiers: tiersCount, columnX: col.minX, columnW: col.width, config: activeConfig)
                        let lbl = "\(colNames[cIdx]) · \(tierSubLabel(index: t, total: tiersCount)) (\(step + 1)/\(totalSteps))"
                        quads.append(ComicTierQuadrant(
                            id: step,
                            columnIndex: cIdx,
                            tierIndex: t,
                            totalColumns: 2,
                            totalTiersInColumn: tiersCount,
                            stepOrder: step,
                            totalInPage: totalSteps,
                            normalizedRect: rect,
                            label: lbl
                        ))
                        step += 1
                    }
                }
            }

            return quads
        }

        // Auto Gutter preset
        if activeConfig.preset == .autoGutter, let img = imageForGutterAnalysis {
            let gutters = findHorizontalGutterRatios(in: img, startRatio: 0.22, endRatio: 0.78, maxGutters: 2)
            if gutters.count == 2 {
                let g1 = Double(gutters[0])
                let g2 = Double(gutters[1])
                let rect1 = CGRect(x: leftTrim, y: 1.0 - g1, width: activeW, height: g1)
                let rect2 = CGRect(x: leftTrim, y: 1.0 - g2, width: activeW, height: g2 - g1)
                let rect3 = CGRect(x: leftTrim, y: 0.0, width: activeW, height: 1.0 - g2)
                return [
                    ComicTierQuadrant(id: 0, columnIndex: 0, tierIndex: 0, totalColumns: 1, totalTiersInColumn: 3, stepOrder: 0, totalInPage: 3, normalizedRect: rect1, label: "Top Tier (1/3)"),
                    ComicTierQuadrant(id: 1, columnIndex: 0, tierIndex: 1, totalColumns: 1, totalTiersInColumn: 3, stepOrder: 1, totalInPage: 3, normalizedRect: rect2, label: "Middle Tier (2/3)"),
                    ComicTierQuadrant(id: 2, columnIndex: 0, tierIndex: 2, totalColumns: 1, totalTiersInColumn: 3, stepOrder: 2, totalInPage: 3, normalizedRect: rect3, label: "Bottom Tier (3/3)")
                ]
            } else if gutters.count == 1 {
                let g = Double(gutters[0])
                let rect1 = CGRect(x: leftTrim, y: 1.0 - g, width: activeW, height: g)
                let rect2 = CGRect(x: leftTrim, y: 0, width: activeW, height: 1.0 - g)
                return [
                    ComicTierQuadrant(id: 0, columnIndex: 0, tierIndex: 0, totalColumns: 1, totalTiersInColumn: 2, stepOrder: 0, totalInPage: 2, normalizedRect: rect1, label: "Top Half (1/2)"),
                    ComicTierQuadrant(id: 1, columnIndex: 0, tierIndex: 1, totalColumns: 1, totalTiersInColumn: 2, stepOrder: 1, totalInPage: 2, normalizedRect: rect2, label: "Bottom Half (2/2)")
                ]
            }
        }

        // 2-Column / Yonkoma Mode
        if activeConfig.preset == .yonkoma || activeConfig.columnCount == 2 {
            let split = max(0.2, min(0.8, CGFloat(activeConfig.columnSplitRatio)))
            let gutter: CGFloat = 0.02 * activeW
            let col0W = max(0.05, (activeW * split) - (gutter / 2.0))
            let col1X = leftTrim + (activeW * split) + (gutter / 2.0)
            let col1W = max(0.05, (leftTrim + activeW) - col1X)
            let leftCol = CGRect(x: leftTrim, y: 0.0, width: col0W, height: 1.0)
            let rightCol = CGRect(x: col1X, y: 0.0, width: col1W, height: 1.0)

            let cols = effectiveRTL ? [rightCol, leftCol] : [leftCol, rightCol]
            let colNames = effectiveRTL ? ["Right Col", "Left Col"] : ["Left Col", "Right Col"]

            let tiersCount = max(2, min(4, activeConfig.tierCount))
            let totalSteps = tiersCount * 2
            var quads: [ComicTierQuadrant] = []
            var step = 0

            if activeConfig.flowOrder == .rowFirst {
                for t in 0..<tiersCount {
                    for (cIdx, col) in cols.enumerated() {
                        let rect = computeTierRect(tierIndex: t, totalTiers: tiersCount, columnX: col.minX, columnW: col.width, config: activeConfig)
                        let subLbl = tierSubLabel(index: t, total: tiersCount)
                        let lbl = "\(colNames[cIdx]) · \(subLbl) (\(step + 1)/\(totalSteps))"
                        quads.append(ComicTierQuadrant(
                            id: step,
                            columnIndex: cIdx,
                            tierIndex: t,
                            totalColumns: 2,
                            totalTiersInColumn: tiersCount,
                            stepOrder: step,
                            totalInPage: totalSteps,
                            normalizedRect: rect,
                            label: lbl
                        ))
                        step += 1
                    }
                }
            } else {
                for (cIdx, col) in cols.enumerated() {
                    for t in 0..<tiersCount {
                        let rect = computeTierRect(tierIndex: t, totalTiers: tiersCount, columnX: col.minX, columnW: col.width, config: activeConfig)
                        let subLbl = tierSubLabel(index: t, total: tiersCount)
                        let lbl = "\(colNames[cIdx]) · \(subLbl) (\(step + 1)/\(totalSteps))"
                        quads.append(ComicTierQuadrant(
                            id: step,
                            columnIndex: cIdx,
                            tierIndex: t,
                            totalColumns: 2,
                            totalTiersInColumn: tiersCount,
                            stepOrder: step,
                            totalInPage: totalSteps,
                            normalizedRect: rect,
                            label: lbl
                        ))
                        step += 1
                    }
                }
            }

            return quads
        }

        // Single Column (3 Tiers, 2 Halves, 4 Tiers)
        let tiersCount = max(2, min(5, activeConfig.tierCount))
        var quads: [ComicTierQuadrant] = []
        for t in 0..<tiersCount {
            let rect = computeTierRect(tierIndex: t, totalTiers: tiersCount, columnX: leftTrim, columnW: activeW, config: activeConfig)
            let subLbl = tierSubLabel(index: t, total: tiersCount)
            let lbl = "\(subLbl) (\(t + 1)/\(tiersCount))"
            quads.append(ComicTierQuadrant(
                id: t,
                columnIndex: 0,
                tierIndex: t,
                totalColumns: 1,
                totalTiersInColumn: tiersCount,
                stepOrder: t,
                totalInPage: tiersCount,
                normalizedRect: rect,
                label: lbl
            ))
        }

        return quads
    }

    private static func computeTierRect(
        tierIndex: Int,
        totalTiers: Int,
        columnX: CGFloat,
        columnW: CGFloat,
        config: ComicTierGuideConfiguration
    ) -> CGRect {
        let topTrim = max(0.0, min(0.12, CGFloat(config.topMarginTrim)))
        let botTrim = max(0.0, min(0.12, CGFloat(config.bottomMarginTrim)))
        let usableH = max(0.5, 1.0 - (topTrim + botTrim))
        let overlap = max(0.05, min(0.30, CGFloat(config.overlap)))

        let rawH = usableH / CGFloat(totalTiers)
        let effectiveH = min(1.0, rawH * (1.0 + overlap))

        // In Vision coords, Y=1 is Top, Y=0 is Bottom.
        let stepFraction = CGFloat(tierIndex) / CGFloat(max(1, totalTiers - 1))
        let maxY = (1.0 - topTrim)
        let minY = botTrim

        let tierMaxY = maxY - (stepFraction * max(0.0, (maxY - minY - effectiveH)))
        let tierMinY = max(minY, tierMaxY - effectiveH)

        return CGRect(
            x: columnX,
            y: tierMinY,
            width: columnW,
            height: max(0.05, tierMaxY - tierMinY)
        )
    }

    private static func tierSubLabel(index: Int, total: Int) -> String {
        if total == 3 {
            return index == 0 ? "Top Tier" : (index == 1 ? "Middle Tier" : "Bottom Tier")
        } else if total == 2 {
            return index == 0 ? "Top Half" : "Bottom Half"
        } else if total == 4 {
            return "Tier \(index + 1) of 4"
        }
        return "Tier \(index + 1)"
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
