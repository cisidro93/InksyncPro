import Foundation
import UIKit
import CoreGraphics
import CoreImage
import Combine
import ImageIO
import ZIPFoundation


// ============================================================================
// SpreadPair
// ============================================================================
// A spread pair represents the two pages that appear side-by-side in dual-page
// mode. In LTR mode: left = even index, right = odd index (after page 0 cover).
// In Manga (RTL) mode: right = current, left = next.
//
// Page 0 (cover) is always a solo spread.
// Any page whose image is wider than tall (a physical spread) forces solo display.
// ============================================================================
struct SpreadPair {
    let leftIndex: Int?   // nil = blank gutter slot
    let rightIndex: Int?  // nil = blank gutter slot

    var leftImage: CGImage?
    var rightImage: CGImage?

    /// The "primary" index for progress tracking — always the first in reading order.
    var leadIndex: Int { leftIndex ?? rightIndex ?? 0 }
}

// ============================================================================
// PageBufferManager
// ============================================================================
// Dual-page aware, look-ahead buffer engine. In single-page mode behaviour is
// unchanged. In dual-page mode the manager preloads a full spread window:
//   currentLeft, currentRight, prevLeft, prevRight, nextLeft, nextRight
// so that every page turn has zero-latency.
// ============================================================================
@MainActor
class PageBufferManager: ObservableObject {
    static let shared = PageBufferManager()
    private init() {}

    // MARK: - Published State (Single Page Mode)
    @Published var currentImage: CGImage?
    @Published var nextImage: CGImage?
    @Published var prevImage: CGImage?
    @Published var isLoading: Bool = false

    // MARK: - Published State (Dual Page Mode)
    @Published var currentSpread: SpreadPair?
    @Published var nextSpread: SpreadPair?
    @Published var prevSpread: SpreadPair?

    // MARK: - PPL State
    @Published var isPPLEnabled: Bool = false
    @Published var lockedRect: NormalizedRect = .full

    // MARK: - Decode Progress (0.0 → 1.0)
    /// Exposed so PPLReaderView can show a real progress bar instead of a spinner
    @Published var decodeProgress: Double = 0.0

    // MARK: - Internal
    private var pageURLs: [URL] = []
    private var archiveURL: URL?
    private var zipEntries: [ZIPFoundation.Entry] = []
    private var renderTask: Task<Void, Never>?
    /// Incremented every time setup() is called. Any decode that finishes after a new
    /// setup() has started is stale — it must not write to any @Published property.
    private var generation: Int = 0
    private var lastPageTurnTime: Date = Date()
    private var isSkimming: Bool = false

    // ✅ Phase 1: Smart Margin Cropping
    var isAutoCropEnabled: Bool {
        UserDefaults.standard.bool(forKey: "isAutoCropEnabled")
    }

    // MARK: - Setup

    func setup(pages: [URL]) {
        // Cancel any in-flight decode from the previous file BEFORE overwriting pageURLs.
        // Without this, a Task.detached started for the old file can finish AFTER setup()
        // and overwrite currentImage with a stale page from the wrong file.
        renderTask?.cancel()
        renderTask = nil
        generation &+= 1      // wrapping add — safe at Int.max
        pageURLs = pages
        archiveURL = nil
        zipEntries = []
        lockedRect = .full
        currentImage = nil
        nextImage = nil
        prevImage = nil
        currentSpread = nil
        nextSpread = nil
        prevSpread = nil
        lastPageTurnTime = Date()
        isSkimming = false
    }

    func setupDirectArchive(url: URL) {
        renderTask?.cancel()
        renderTask = nil
        generation &+= 1
        
        archiveURL = url
        lockedRect = .full
        currentImage = nil
        nextImage = nil
        prevImage = nil
        currentSpread = nil
        nextSpread = nil
        prevSpread = nil
        lastPageTurnTime = Date()
        isSkimming = false
        
        do {
            let archive = try Archive(url: url, accessMode: .read)
            let entries = archive.filter { entry in
                let name = entry.path
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                let filename = URL(fileURLWithPath: name).lastPathComponent
                return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext)
                    && !name.contains("__MACOSX")
                    && !filename.hasPrefix("._")
                    && filename != ".DS_Store"
                    && !name.hasSuffix("/")
            }.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            self.zipEntries = entries
            self.pageURLs = entries.map { url.appendingPathComponent($0.path) }
            
            Logger.shared.log("PageBufferManager: Setup direct ZIP streaming with \(entries.count) pages", category: "Engine", type: .success)
        } catch {
            Logger.shared.log("PageBufferManager: Failed to parse ZIP archive: \(error.localizedDescription)", category: "Engine", type: .error)
            self.zipEntries = []
            self.pageURLs = []
        }
    }
    
    static func findArchiveURL(in url: URL) -> URL? {
        let path = url.path
        if let range = path.range(of: ".cbz", options: .caseInsensitive) {
            let archivePath = String(path[..<range.upperBound])
            return URL(fileURLWithPath: archivePath)
        }
        if let range = path.range(of: ".zip", options: .caseInsensitive) {
            let archivePath = String(path[..<range.upperBound])
            return URL(fileURLWithPath: archivePath)
        }
        return nil
    }

    func updateViewport(rect: NormalizedRect) {
        lockedRect = rect
    }

    // MARK: - Single Page Render

    func render(pageIndex: Int, bounds: CGSize) {
        let now = Date()
        let interval = now.timeIntervalSince(lastPageTurnTime)
        lastPageTurnTime = now
        let wasSkimming = isSkimming
        isSkimming = (interval < 0.4) // skimming if turned within 400ms

        renderTask?.cancel()
        let gen = generation          // capture — guards against stale writes
        renderTask = Task {
            self.isLoading = true

            if isSkimming {
                // 1. Skimming: Decode a low-res thumbnail first for absolute zero latency
                let thumbBounds = CGSize(width: 512, height: 512)
                let lowResImage = await renderPage(at: pageIndex, bounds: thumbBounds)
                
                if !Task.isCancelled, self.generation == gen {
                    self.currentImage = lowResImage
                    self.nextImage = nil
                    self.prevImage = nil
                    self.isLoading = false
                }
                
                // Dwell check: Wait 400ms. If user stops skimming, promote to full resolution.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, self.generation == gen else { return }
                
                // Promote to high resolution
                let fullImage = await renderPage(at: pageIndex, bounds: bounds)
                if !Task.isCancelled, self.generation == gen {
                    self.currentImage = fullImage
                }
            } else {
                // 1. Normal Mode: Decode full resolution immediately
                let cImage = await renderPage(at: pageIndex, bounds: bounds)
                
                if !Task.isCancelled, self.generation == gen {
                    self.currentImage = cImage
                    self.isLoading = false
                }
                
                if wasSkimming {
                    // Settle delay: if we just stopped skimming, wait 150ms to ensure the user has rested
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, self.generation == gen else { return }
                }
            }

            // 2. Load neighbors in background (sequential on low-end, concurrent on others)
            let perfClass = ProcessInfo.processInfo.performanceClass
            if perfClass == .low {
                // Low end: load next page then prev page sequentially to avoid concurrent memory spikes
                let nImage = await renderPage(at: pageIndex + 1, bounds: bounds)
                if !Task.isCancelled, self.generation == gen {
                    self.nextImage = nImage
                }
                let pImage = await renderPage(at: pageIndex - 1, bounds: bounds)
                if !Task.isCancelled, self.generation == gen {
                    self.prevImage = pImage
                }
            } else {
                // Medium/High: concurrent preload of both next and prev
                async let next = renderPage(at: pageIndex + 1, bounds: bounds)
                async let prev = renderPage(at: pageIndex - 1, bounds: bounds)
                let (nImage, pImage) = await (next, prev)
                if !Task.isCancelled, self.generation == gen {
                    self.nextImage = nImage
                    self.prevImage = pImage
                }
            }

            emitNearingEndIfNeeded(at: pageIndex)
        }
    }

    // MARK: - Dual Page Render

    /// Render a spread window around `leadIndex` (the left page of the current spread).
    /// `isMangaMode` controls which physical page index maps to left vs right.
    func renderDual(leadIndex: Int, pages allPages: [URL], isMangaMode: Bool, bounds: CGSize? = nil) {
        let now = Date()
        let interval = now.timeIntervalSince(lastPageTurnTime)
        lastPageTurnTime = now
        let wasSkimming = isSkimming
        isSkimming = (interval < 0.4) // skimming if turned within 400ms

        renderTask?.cancel()
        let gen = generation          // capture — guards against stale writes
        renderTask = Task {
            self.isLoading = true
            self.decodeProgress = 0.0

            // Build the three spread pairs: prev, current, next
            let curPair  = buildSpreadPair(leadIndex: leadIndex, allPages: allPages, isMangaMode: isMangaMode)
            let prevPair = buildSpreadPair(leadIndex: leadIndex - 2, allPages: allPages, isMangaMode: isMangaMode)
            let nextPair = buildSpreadPair(leadIndex: leadIndex + 2, allPages: allPages, isMangaMode: isMangaMode)

            let pageBounds: CGSize? = {
                if let bounds = bounds, bounds.width > 0, bounds.height > 0 {
                    return CGSize(width: bounds.width / 2.0, height: bounds.height)
                }
                return nil
            }()

            if isSkimming {
                // 1. Skimming: Decode low-res thumbnails first for absolute zero latency
                let thumbBounds = CGSize(width: 384, height: 384)
                async let curL  = renderPage(at: curPair.leftIndex, bounds: thumbBounds)
                async let curR  = renderPage(at: curPair.rightIndex, bounds: thumbBounds)
                let cL = await curL
                let cR = await curR

                if !Task.isCancelled, self.generation == gen {
                    self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cL, rightImage: cR)
                    self.currentImage  = cL ?? cR
                    self.nextSpread = nil
                    self.prevSpread = nil
                    self.nextImage = nil
                    self.prevImage = nil
                    self.isLoading     = false  // UI unlocks here
                }

                // Dwell check: Wait 400ms. If user stops skimming, promote to full resolution.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, self.generation == gen else { return }

                // Promote to high resolution
                async let curLFull  = renderPage(at: curPair.leftIndex, bounds: pageBounds)
                async let curRFull  = renderPage(at: curPair.rightIndex, bounds: pageBounds)
                let cLFull = await curLFull
                let cRFull = await curRFull

                if !Task.isCancelled, self.generation == gen {
                    self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cLFull, rightImage: cRFull)
                    self.currentImage  = cLFull ?? cRFull
                }
            } else {
                // 1. Normal Mode: Decode full resolution immediately
                async let curL  = renderPage(at: curPair.leftIndex, bounds: pageBounds)
                async let curR  = renderPage(at: curPair.rightIndex, bounds: pageBounds)
                let cL = await curL;  self.decodeProgress = 1/6
                let cR = await curR;  self.decodeProgress = 2/6

                if !Task.isCancelled, self.generation == gen {
                    self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cL, rightImage: cR)
                    self.currentImage  = cL ?? cR
                    self.isLoading     = false  // UI unlocks here
                }

                if wasSkimming {
                    // Settle delay: if we just stopped skimming, wait 150ms to ensure the user has rested
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, self.generation == gen else { return }
                }
            }

            // 2. Decode background pairs
            let perfClass = ProcessInfo.processInfo.performanceClass
            if perfClass == .low {
                // Low end: Load next spread sequentially, then prev spread sequentially to avoid memory spikes.
                let nL = await renderPage(at: nextPair.leftIndex, bounds: pageBounds);  self.decodeProgress = 3/6
                let nR = await renderPage(at: nextPair.rightIndex, bounds: pageBounds); self.decodeProgress = 4/6
                
                guard !Task.isCancelled, self.generation == gen else { return }
                self.nextSpread = SpreadPair(leftIndex: nextPair.leftIndex, rightIndex: nextPair.rightIndex, leftImage: nL, rightImage: nR)
                self.nextImage = nL ?? nR
                
                let pL = await renderPage(at: prevPair.leftIndex, bounds: pageBounds);  self.decodeProgress = 5/6
                let pR = await renderPage(at: prevPair.rightIndex, bounds: pageBounds); self.decodeProgress = 6/6
                
                guard !Task.isCancelled, self.generation == gen else { return }
                self.prevSpread = SpreadPair(leftIndex: prevPair.leftIndex, rightIndex: prevPair.rightIndex, leftImage: pL, rightImage: pR)
                self.prevImage = pL ?? pR
            } else {
                // Medium/High: concurrent preload of both prev and next spreads
                async let prevL = renderPage(at: prevPair.leftIndex, bounds: pageBounds)
                async let prevR = renderPage(at: prevPair.rightIndex, bounds: pageBounds)
                async let nextL = renderPage(at: nextPair.leftIndex, bounds: pageBounds)
                async let nextR = renderPage(at: nextPair.rightIndex, bounds: pageBounds)
                
                let pL = await prevL; self.decodeProgress = 3/6
                let pR = await prevR; self.decodeProgress = 4/6
                let nL = await nextL; self.decodeProgress = 5/6
                let nR = await nextR; self.decodeProgress = 6/6
                
                guard !Task.isCancelled, self.generation == gen else { return }
                
                self.prevSpread = SpreadPair(leftIndex: prevPair.leftIndex, rightIndex: prevPair.rightIndex, leftImage: pL, rightImage: pR)
                self.nextSpread = SpreadPair(leftIndex: nextPair.leftIndex, rightIndex: nextPair.rightIndex, leftImage: nL, rightImage: nR)
                
                self.nextImage    = nL ?? nR
                self.prevImage    = pL ?? pR
            }

            self.isLoading = false
            emitNearingEndIfNeeded(at: leadIndex)
        }
    }

    // MARK: - Spread Layout Engine

    /// Determine which two page indices form a spread whose left (or Manga right)
    /// is at `leadIndex`. Returns a raw index pair — rendering is done separately.
    ///
    /// Rules:
    ///  - Page 0 is always solo (cover).
    ///  - Any page wider than tall (physical spread) is always solo.
    ///  - All other pages are paired: even index = left, odd index = right.
    func buildSpreadPair(leadIndex: Int, allPages: [URL], isMangaMode: Bool) -> (leftIndex: Int?, rightIndex: Int?) {
        let total = allPages.count
        guard leadIndex >= 0, leadIndex < total else { return (nil, nil) }

        // Cover is always solo — left slot holds the cover, right is blank
        if leadIndex == 0 {
            return isMangaMode ? (nil, 0) : (0, nil)
        }

        // Determine the right index
        let rightIndex = leadIndex + 1 < total ? leadIndex + 1 : nil

        if isMangaMode {
            return (rightIndex, leadIndex)
        } else {
            return (leadIndex, rightIndex)
        }
    }

    /// Given a `currentPageIndex` (the leading page in the pair), compute the
    /// canonical lead index for dual-page mode. This ensures parity is maintained
    /// when jumping to arbitrary pages.
    ///
    /// Rule: In LTR mode, even-numbered pages (1, 3, 5...) are always left-page leads.
    /// The cover (0) is solo. So lead indices are: 0, 1, 3, 5, 7...
    static func canonicalLeadIndex(for rawIndex: Int, isMangaMode: Bool) -> Int {
        if rawIndex <= 0 { return 0 }
        // After the cover, spreads start at index 1.
        // Index 1 = lead for spread (1,2), index 3 = lead for (3,4), etc.
        let offset = rawIndex - 1
        let leadOffset = (offset / 2) * 2
        return 1 + leadOffset
    }

    // MARK: - Private Helpers

    private func renderPage(at index: Int?, bounds: CGSize? = nil) async -> CGImage? {
        guard let index = index, index >= 0, index < pageURLs.count else { return nil }
        let url = pageURLs[index]

        let scale = await MainActor.run { UIScreen.main.scale }
        let perfClass = ProcessInfo.processInfo.performanceClass
        let maxPixelSize: CGFloat? = {
            if let bounds = bounds, bounds.width > 0, bounds.height > 0 {
                let maxDim = max(bounds.width, bounds.height)
                switch perfClass {
                case .low:
                    // Low-tier gets slightly under Retina to save memory
                    return maxDim * min(scale, 1.5)
                case .medium:
                    // Medium-tier gets exact Retina resolution
                    return maxDim * scale
                case .high:
                    // High-tier gets super-sampled Retina resolution (1.5x Retina) for pin-sharp zooms
                    return maxDim * scale * 1.5
                }
            } else {
                switch perfClass {
                case .low:
                    return 1536
                case .medium:
                    return 2048
                case .high:
                    return 3072
                }
            }
        }()

        if let archiveURL = self.archiveURL, index < zipEntries.count {
            let entryPath = zipEntries[index].path
            return await Task.detached(priority: .userInitiated) {
                var cgImage: CGImage? = nil
                autoreleasepool {
                    do {
                        let archive = try Archive(url: archiveURL, accessMode: .read)
                        guard let entry = archive[entryPath] else { return }
                        var data = Data()
                        _ = try archive.extract(entry) { chunk in
                            data.append(chunk)
                        }
                        
                        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                            let options: [CFString: Any]
                            if let maxSize = maxPixelSize {
                                options = [
                                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: Int(maxSize),
                                    kCGImageSourceShouldCacheImmediately: true
                                ]
                            } else {
                                options = [
                                    kCGImageSourceShouldCacheImmediately: true
                                ]
                            }
                            
                            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                        }
                    } catch {
                        Logger.shared.log("Direct ZIP decompression failed for entry \(entryPath): \(error.localizedDescription)", category: "Engine", type: .error)
                    }
                }
                
                guard let image = cgImage else { return nil }
                let cropEnabled = await MainActor.run { self.isAutoCropEnabled }
                return cropEnabled ? Self.autoCropMargins(from: image) : image
            }.value
        }

        return await Task.detached(priority: .userInitiated) {
            // Strategy 1: CGImageSource (fastest, best memory usage)
            var cgImage: CGImage? = nil
            autoreleasepool {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let options: [CFString: Any]
                    if let maxSize = maxPixelSize {
                        options = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: Int(maxSize),
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                    } else {
                        options = [
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                    }
                    cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }
            }

            if let image = cgImage {
                let cropEnabled = await MainActor.run { self.isAutoCropEnabled }
                return cropEnabled ? Self.autoCropMargins(from: image) : image
            }

            // Strategy 2: UIImage fallback (different OS codec path — handles some edge cases
            // where CGImageSource returns nil for valid JPEGs on certain iOS versions)
            var fallbackImage: CGImage? = nil
            autoreleasepool {
                if let uiImage = UIImage(contentsOfFile: url.path), let cgImage = uiImage.cgImage {
                    fallbackImage = cgImage
                }
            }

            if let cgImage = fallbackImage {
                await MainActor.run {
                    Logger.shared.log(
                        "PageBufferManager: CGImageSource failed but UIImage succeeded for page \(index) — \(url.lastPathComponent)",
                        category: "Engine", type: .warning
                    )
                }
                let cropEnabled = await MainActor.run { self.isAutoCropEnabled }
                let finalImage = cropEnabled ? Self.autoCropMargins(from: cgImage) : cgImage
                
                if let maxSize = maxPixelSize, CGFloat(max(finalImage.width, finalImage.height)) > maxSize {
                    return autoreleasepool {
                        Self.downsample(cgImage: finalImage, toMaxPixelSize: Int(maxSize))
                    }
                }
                return finalImage
            }

            // Both strategies failed — log diagnostic info
            let exists = FileManager.default.fileExists(atPath: url.path)
            await MainActor.run {
                Logger.shared.log(
                    "PageBufferManager: DECODE FAILED page \(index) | exists=\(exists) | path=\(url.path)",
                    category: "Engine", type: .error
                )
            }
            return nil
        }.value
    }

    nonisolated private static func downsample(cgImage: CGImage, toMaxPixelSize maxSize: Int) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        let maxDim = max(width, height)
        guard maxDim > maxSize else { return cgImage }
        
        let scale = CGFloat(maxSize) / CGFloat(maxDim)
        let newWidth = Int(CGFloat(width) * scale)
        let newHeight = Int(CGFloat(height) * scale)
        
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: newWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return cgImage }
        
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? cgImage
    }

    private func emitNearingEndIfNeeded(at index: Int) {
        let total = pageURLs.count
        guard total > 0, index >= total - 5 else { return }
        NotificationCenter.default.post(
            name: NSNotification.Name("Reader_NearingEnd"),
            object: nil,
            userInfo: ["pagesRemaining": total - index]
        )
    }

    // MARK: - Smart Margin Crop Engine

    nonisolated static func autoCropMargins(from image: CGImage) -> CGImage {
        return autoreleasepool {
            guard let data = image.dataProvider?.data,
                  let ptr = CFDataGetBytePtr(data) else { return image }

            let width = image.width
            let height = image.height
            let bytesPerRow = image.bytesPerRow
            let bytesPerPixel = image.bitsPerPixel / 8
            guard bytesPerPixel >= 3 else { return image }

            let threshold: UInt8 = 245
            let strideVal = 8

            // Top margin search
            var top = 0
            var foundTopRow = -1
            for y in stride(from: 0, to: height, by: strideVal) {
                let rowOffset = y * bytesPerRow
                var found = false
                for x in stride(from: 0, to: width, by: 10) {
                    let o = rowOffset + (x * bytesPerPixel)
                    if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    foundTopRow = y
                    break
                }
            }
            if foundTopRow != -1 {
                let startY = max(0, foundTopRow - strideVal + 1)
                for y in startY...foundTopRow {
                    let rowOffset = y * bytesPerRow
                    var found = false
                    for x in stride(from: 0, to: width, by: 10) {
                        let o = rowOffset + (x * bytesPerPixel)
                        if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                            found = true
                            break
                        }
                    }
                    if found {
                        top = y
                        break
                    }
                }
            }

            // Bottom margin search
            var bottom = height - 1
            var foundBottomRow = -1
            for y in stride(from: height - 1, through: top, by: -strideVal) {
                let rowOffset = y * bytesPerRow
                var found = false
                for x in stride(from: 0, to: width, by: 10) {
                    let o = rowOffset + (x * bytesPerPixel)
                    if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    foundBottomRow = y
                    break
                }
            }
            if foundBottomRow != -1 {
                let startY = min(height - 1, foundBottomRow + strideVal - 1)
                for y in stride(from: startY, through: foundBottomRow, by: -1) {
                    let rowOffset = y * bytesPerRow
                    var found = false
                    for x in stride(from: 0, to: width, by: 10) {
                        let o = rowOffset + (x * bytesPerPixel)
                        if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                            found = true
                            break
                        }
                    }
                    if found {
                        bottom = y
                        break
                    }
                }
            }

            // Left margin search
            var left = 0
            var foundLeftCol = -1
            for x in stride(from: 0, to: width, by: strideVal) {
                var found = false
                for y in stride(from: top, to: bottom, by: 10) {
                    let o = (y * bytesPerRow) + (x * bytesPerPixel)
                    if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    foundLeftCol = x
                    break
                }
            }
            if foundLeftCol != -1 {
                let startX = max(0, foundLeftCol - strideVal + 1)
                for x in startX...foundLeftCol {
                    var found = false
                    for y in stride(from: top, to: bottom, by: 10) {
                        let o = (y * bytesPerRow) + (x * bytesPerPixel)
                        if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                            found = true
                            break
                        }
                    }
                    if found {
                        left = x
                        break
                    }
                }
            }

            // Right margin search
            var right = width - 1
            var foundRightCol = -1
            for x in stride(from: width - 1, through: left, by: -strideVal) {
                var found = false
                for y in stride(from: top, to: bottom, by: 10) {
                    let o = (y * bytesPerRow) + (x * bytesPerPixel)
                    if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                        found = true
                        break
                    }
                }
                if found {
                    foundRightCol = x
                    break
                }
            }
            if foundRightCol != -1 {
                let startX = min(width - 1, foundRightCol + strideVal - 1)
                for x in stride(from: startX, through: foundRightCol, by: -1) {
                    var found = false
                    for y in stride(from: top, to: bottom, by: 10) {
                        let o = (y * bytesPerRow) + (x * bytesPerPixel)
                        if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                            found = true
                            break
                        }
                    }
                    if found {
                        right = x
                        break
                    }
                }
            }

            let pad = 10
            let cropRect = CGRect(
                x: max(0, left - pad),
                y: max(0, top - pad),
                width: min(width - 1, right + pad) - max(0, left - pad),
                height: min(height - 1, bottom + pad) - max(0, top - pad)
            )

            guard cropRect.width > CGFloat(width) * 0.3,
                  cropRect.height > CGFloat(height) * 0.3 else { return image }

            return image.cropping(to: cropRect) ?? image
        }
    }
}
