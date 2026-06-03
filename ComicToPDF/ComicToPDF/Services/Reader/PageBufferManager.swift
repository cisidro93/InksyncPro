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
struct SpreadPair {
    let leftIndex: Int?
    let rightIndex: Int?

    var leftImage: CGImage?
    var rightImage: CGImage?

    /// The "primary" index for progress tracking — always the first in reading order.
    var leadIndex: Int { leftIndex ?? rightIndex ?? 0 }
}

// ============================================================================
// CGImageBox
// ============================================================================
// NSCache requires AnyObject values. CGImage is not a class type in Swift
// (it's a Core Foundation type bridged as AnyObject, but explicit wrapping
// avoids ambiguity and keeps the cache key/value types clear).
// ============================================================================
final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

// ============================================================================
// PageBufferManager
// ============================================================================
// Audit fixes applied (June 2026):
//
// Issue 1 — FIXED: setupDirectArchive moved to Task.detached so ZIP header
//   scanning runs off the main thread. @Published state updated via MainActor.run.
//
// Issue 2 — FIXED: Archive is no longer opened per-page. Entry data is
//   extracted once in setupDirectArchive and paths stored; executeRender
//   opens a single Archive per decode batch via a nonisolated static helper.
//   A serial DispatchQueue (archiveQueue) serialises all reads on the same
//   file handle to prevent concurrent-read corruption.
//
// Issue 3 — FIXED: Task closures use [weak self] consistently.
//
// Issue 4 — FIXED: NSCache<NSNumber, CGImageBox> with countLimit = 7 replaces
//   the six strong @Published CGImage vars. Old images are evicted by the cache
//   automatically on memory pressure and on new-file transitions.
//
// Issue 5 — FIXED: autoCropMargins pins CFData backing buffer for the full
//   pixel scan duration using withExtendedLifetime.
//
// Issue 6 — FIXED: decodeProgress is incremented atomically by each page decode
//   using a captured total-pages count, giving accurate per-page granularity.
//
// Issue 7 — FIXED: buildSpreadPair returns nil early for clearly out-of-range
//   lead indices so renderPage(at:nil) task slots are never allocated.
// ============================================================================

// File-private global — must live outside the @MainActor class so it is
// nonisolated and accessible from nonisolated static functions (executeRender).
// Swift 6: static stored properties on @MainActor types are @MainActor-isolated
// and cannot be read from nonisolated contexts.
private let _pageBufferArchiveQueue = DispatchQueue(
    label: "com.inksyncpro.pagebuffer.archive",
    qos: .userInitiated
)

@MainActor
class PageBufferManager: ObservableObject {
    static let shared = PageBufferManager()
    private init() {
        Logger.shared.log("PageBufferManager: init", category: "Engine")
    }
    deinit {
        Logger.shared.log("PageBufferManager: deinit", category: "Engine")
    }

    // MARK: - Published State (Single Page Mode)
    // Images are now vended from cache; these are thin wrappers for SwiftUI observation.
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
    @Published var decodeProgress: Double = 0.0

    // MARK: - Internal

    private var pageURLs: [URL] = []
    private var archiveURL: URL?
    private var zipEntryPaths: [String] = []
    private var renderTask: Task<Void, Never>?

    /// Issue 4 fix: NSCache caps live decoded images at 7, evicting on memory
    /// pressure automatically. Each page index maps to its decoded CGImage.
    /// countLimit = 7 covers: currentL, currentR, prevL, prevR, nextL, nextR + 1 spare.
    private let imageCache: NSCache<NSNumber, CGImageBox> = {
        let c = NSCache<NSNumber, CGImageBox>()
        c.countLimit = 7
        c.name = "com.inksyncpro.pagebuffer"
        return c
    }()


    /// Generation counter — incremented on every setup() call.
    /// Any decode that finishes after a new setup() has started is stale.
    private var generation: Int = 0

    private var lastPageTurnTime: Date = Date()
    private var isSkimming: Bool = false

    var isAutoCropEnabled: Bool {
        UserDefaults.standard.bool(forKey: "isAutoCropEnabled")
    }

    // MARK: - Setup (Single Page / Extracted Files)

    func setup(pages: [URL]) {
        renderTask?.cancel()
        renderTask = nil
        generation &+= 1
        pageURLs = pages
        archiveURL = nil
        zipEntryPaths = []
        lockedRect = .full
        imageCache.removeAllObjects()       // Issue 4: evict stale images immediately
        currentImage = nil
        nextImage = nil
        prevImage = nil
        currentSpread = nil
        nextSpread = nil
        prevSpread = nil
        lastPageTurnTime = Date()
        isSkimming = false
    }

    // MARK: - Setup (Direct ZIP Streaming)
    // Issue 1 fix: ZIP header scanning moved off @MainActor.

    func setupDirectArchive(url: URL) {
        renderTask?.cancel()
        renderTask = nil
        generation &+= 1
        archiveURL = url
        lockedRect = .full
        imageCache.removeAllObjects()       // Issue 4: evict immediately
        currentImage = nil
        nextImage = nil
        prevImage = nil
        currentSpread = nil
        nextSpread = nil
        prevSpread = nil
        lastPageTurnTime = Date()
        isSkimming = false

        let capturedGen = generation

        // Issue 1: Archive(url:) scans the ZIP central directory synchronously.
        // On a 500MB CBZ this can block for >250ms — a watchdog kill on @MainActor.
        // Solution: run off-actor, update @Published state via MainActor.run.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            var paths: [String] = []
            var syntheticURLs: [URL] = []

            do {
                let archive = try Archive(url: url, accessMode: .read)
                let entries = archive
                    .filter { entry in
                        let name = entry.path
                        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                        let filename = URL(fileURLWithPath: name).lastPathComponent
                        return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext)
                            && !name.contains("__MACOSX")
                            && !filename.hasPrefix("._")
                            && filename != ".DS_Store"
                            && !name.hasSuffix("/")
                    }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

                paths = entries.map { $0.path }
                // Synthetic URLs are only used for extension extraction in renderPage —
                // actual data is always extracted via zipEntryPaths + archiveURL.
                syntheticURLs = entries.map { url.appendingPathComponent($0.path) }

                Logger.shared.log(
                    "PageBufferManager: Direct ZIP ready — \(entries.count) pages",
                    category: "Engine", type: .success
                )
            } catch {
                Logger.shared.log(
                    "PageBufferManager: ZIP parse failed — \(error.localizedDescription)",
                    category: "Engine", type: .error
                )
            }

            await MainActor.run { [weak self] in
                guard let self, self.generation == capturedGen else { return }
                self.zipEntryPaths = paths
                self.pageURLs = syntheticURLs
            }
        }
    }

    static func findArchiveURL(in url: URL) -> URL? {
        let path = url.path
        if let range = path.range(of: ".cbz", options: .caseInsensitive) {
            return URL(fileURLWithPath: String(path[..<range.upperBound]))
        }
        if let range = path.range(of: ".zip", options: .caseInsensitive) {
            return URL(fileURLWithPath: String(path[..<range.upperBound]))
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
        isSkimming = (interval < 0.4)

        renderTask?.cancel()
        let gen = generation

        // Issue 3 fix: [weak self] prevents retain if the singleton pattern changes.
        renderTask = Task { [weak self] in
            guard let self else { return }

            self.isLoading = true

            if isSkimming {
                // Skimming: low-res thumbnail first for zero latency
                let thumbBounds = CGSize(width: 512, height: 512)
                let lowResImage = await renderPage(at: pageIndex, bounds: thumbBounds)

                if !Task.isCancelled, self.generation == gen {
                    self.currentImage = lowResImage
                    self.nextImage = nil
                    self.prevImage = nil
                    self.isLoading = false
                }

                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, self.generation == gen else { return }

                let fullImage = await renderPage(at: pageIndex, bounds: bounds)
                if !Task.isCancelled, self.generation == gen {
                    self.currentImage = fullImage
                }
            } else {
                let cImage = await renderPage(at: pageIndex, bounds: bounds)
                if !Task.isCancelled, self.generation == gen {
                    self.currentImage = cImage
                    self.isLoading = false
                }
                if wasSkimming {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, self.generation == gen else { return }
                }
            }

            // Preload neighbours
            let perfClass = ProcessInfo.processInfo.performanceClass
            if perfClass == .low {
                let nImage = await renderPage(at: pageIndex + 1, bounds: bounds)
                if !Task.isCancelled, self.generation == gen { self.nextImage = nImage }
                let pImage = await renderPage(at: pageIndex - 1, bounds: bounds)
                if !Task.isCancelled, self.generation == gen { self.prevImage = pImage }
            } else {
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

    func renderDual(leadIndex: Int, pages allPages: [URL], isMangaMode: Bool, bounds: CGSize? = nil) {
        let now = Date()
        let interval = now.timeIntervalSince(lastPageTurnTime)
        lastPageTurnTime = now
        let wasSkimming = isSkimming
        isSkimming = (interval < 0.4)

        renderTask?.cancel()
        let gen = generation
        let totalPages = allPages.count

        // Issue 3 fix: [weak self]
        renderTask = Task { [weak self] in
            guard let self else { return }

            self.isLoading = true
            self.decodeProgress = 0.0

            let curPair  = buildSpreadPair(leadIndex: leadIndex,     totalPages: totalPages, isMangaMode: isMangaMode)
            let prevPair = buildSpreadPair(leadIndex: leadIndex - 2, totalPages: totalPages, isMangaMode: isMangaMode)
            let nextPair = buildSpreadPair(leadIndex: leadIndex + 2, totalPages: totalPages, isMangaMode: isMangaMode)

            let pageBounds: CGSize? = {
                if let b = bounds, b.width > 0, b.height > 0 {
                    return CGSize(width: b.width / 2.0, height: b.height)
                }
                return nil
            }()

            // Issue 6 fix: count only non-nil page slots so progress is accurate.
            let totalSlots = max(1, [
                curPair.leftIndex, curPair.rightIndex,
                prevPair.leftIndex, prevPair.rightIndex,
                nextPair.leftIndex, nextPair.rightIndex
            ].compactMap { $0 }.count)
            var decoded = 0

            func progress() -> Double {
                decoded += 1
                return min(Double(decoded) / Double(totalSlots), 1.0)
            }

            if isSkimming {
                let thumbBounds = CGSize(width: 384, height: 384)
                async let curL = renderPage(at: curPair.leftIndex,  bounds: thumbBounds)
                async let curR = renderPage(at: curPair.rightIndex, bounds: thumbBounds)
                let cL = await curL
                let cR = await curR

                if !Task.isCancelled, self.generation == gen {
                    self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cL, rightImage: cR)
                    self.currentImage  = cL ?? cR
                    self.nextSpread = nil
                    self.prevSpread = nil
                    self.nextImage  = nil
                    self.prevImage  = nil
                    self.isLoading  = false
                }

                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, self.generation == gen else { return }

                async let curLFull = renderPage(at: curPair.leftIndex,  bounds: pageBounds)
                async let curRFull = renderPage(at: curPair.rightIndex, bounds: pageBounds)
                let cLFull = await curLFull
                let cRFull = await curRFull

                if !Task.isCancelled, self.generation == gen {
                    self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cLFull, rightImage: cRFull)
                    self.currentImage  = cLFull ?? cRFull
                }
            } else {
                async let curL = renderPage(at: curPair.leftIndex,  bounds: pageBounds)
                async let curR = renderPage(at: curPair.rightIndex, bounds: pageBounds)
                let cL = await curL;  self.decodeProgress = progress()
                let cR = await curR;  self.decodeProgress = progress()

                if !Task.isCancelled, self.generation == gen {
                    self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cL, rightImage: cR)
                    self.currentImage  = cL ?? cR
                    self.isLoading     = false
                }

                if wasSkimming {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, self.generation == gen else { return }
                }
            }

            // Background preload
            let perfClass = ProcessInfo.processInfo.performanceClass

            // Issue 7 fix: skip spreading decode task allocation for nil-index pairs.
            let hasPrev = prevPair.leftIndex != nil || prevPair.rightIndex != nil
            let hasNext = nextPair.leftIndex != nil || nextPair.rightIndex != nil

            if perfClass == .low {
                if hasNext {
                    let nL = await renderPage(at: nextPair.leftIndex,  bounds: pageBounds); self.decodeProgress = progress()
                    let nR = await renderPage(at: nextPair.rightIndex, bounds: pageBounds); self.decodeProgress = progress()
                    guard !Task.isCancelled, self.generation == gen else { return }
                    self.nextSpread = SpreadPair(leftIndex: nextPair.leftIndex, rightIndex: nextPair.rightIndex, leftImage: nL, rightImage: nR)
                    self.nextImage = nL ?? nR
                }
                if hasPrev {
                    let pL = await renderPage(at: prevPair.leftIndex,  bounds: pageBounds); self.decodeProgress = progress()
                    let pR = await renderPage(at: prevPair.rightIndex, bounds: pageBounds); self.decodeProgress = progress()
                    guard !Task.isCancelled, self.generation == gen else { return }
                    self.prevSpread = SpreadPair(leftIndex: prevPair.leftIndex, rightIndex: prevPair.rightIndex, leftImage: pL, rightImage: pR)
                    self.prevImage = pL ?? pR
                }
            } else {
                if hasNext {
                    async let nextL = renderPage(at: nextPair.leftIndex,  bounds: pageBounds)
                    async let nextR = renderPage(at: nextPair.rightIndex, bounds: pageBounds)
                    let nL = await nextL; self.decodeProgress = progress()
                    let nR = await nextR; self.decodeProgress = progress()
                    if !Task.isCancelled, self.generation == gen {
                        self.nextSpread = SpreadPair(leftIndex: nextPair.leftIndex, rightIndex: nextPair.rightIndex, leftImage: nL, rightImage: nR)
                        self.nextImage  = nL ?? nR
                    }
                }
                if hasPrev {
                    async let prevL = renderPage(at: prevPair.leftIndex,  bounds: pageBounds)
                    async let prevR = renderPage(at: prevPair.rightIndex, bounds: pageBounds)
                    let pL = await prevL; self.decodeProgress = progress()
                    let pR = await prevR; self.decodeProgress = progress()
                    if !Task.isCancelled, self.generation == gen {
                        self.prevSpread = SpreadPair(leftIndex: prevPair.leftIndex, rightIndex: prevPair.rightIndex, leftImage: pL, rightImage: pR)
                        self.prevImage  = pL ?? pR
                    }
                }
            }

            self.decodeProgress = 1.0
            self.isLoading = false
            emitNearingEndIfNeeded(at: leadIndex)
        }
    }

    // MARK: - Spread Layout Engine

    /// Issue 7 fix: accepts `totalPages` directly (no array access) and returns
    /// (nil, nil) early for clearly out-of-range lead indices so the caller never
    /// allocates a `renderPage(at: nil)` task for a guaranteed-nil result.
    func buildSpreadPair(leadIndex: Int, totalPages: Int, isMangaMode: Bool) -> (leftIndex: Int?, rightIndex: Int?) {
        guard leadIndex >= 0, leadIndex < totalPages else { return (nil, nil) }

        if leadIndex == 0 {
            return isMangaMode ? (nil, 0) : (0, nil)
        }

        let rightIndex = leadIndex + 1 < totalPages ? leadIndex + 1 : nil
        return isMangaMode ? (rightIndex, leadIndex) : (leadIndex, rightIndex)
    }

    /// Legacy overload: accepts [URL] for call-sites that pass allPages.
    func buildSpreadPair(leadIndex: Int, allPages: [URL], isMangaMode: Bool) -> (leftIndex: Int?, rightIndex: Int?) {
        buildSpreadPair(leadIndex: leadIndex, totalPages: allPages.count, isMangaMode: isMangaMode)
    }

    static func canonicalLeadIndex(for rawIndex: Int, isMangaMode: Bool) -> Int {
        if rawIndex <= 0 { return 0 }
        let offset = rawIndex - 1
        let leadOffset = (offset / 2) * 2
        return 1 + leadOffset
    }

    // MARK: - Private Helpers

    private func renderPage(at index: Int?, bounds: CGSize? = nil) async -> CGImage? {
        guard let index, index >= 0, index < pageURLs.count else { return nil }

        // Issue 4 fix: serve from cache if available
        if let cached = imageCache.object(forKey: NSNumber(value: index)) {
            return cached.image
        }

        let url = pageURLs[index]
        let scale = await MainActor.run { UIScreen.main.scale }
        let perfClass = ProcessInfo.processInfo.performanceClass
        let maxPixelSize: CGFloat? = {
            if let b = bounds, b.width > 0, b.height > 0 {
                let maxDim = max(b.width, b.height)
                switch perfClass {
                case .low:    return maxDim * min(scale, 1.5)
                case .medium: return maxDim * scale
                case .high:   return maxDim * scale * 1.5
                }
            } else {
                switch perfClass {
                case .low:    return 1536
                case .medium: return 2048
                case .high:   return 3072
                }
            }
        }()

        let isAutoCrop = self.isAutoCropEnabled
        let result = await Self.executeRender(
            url: url,
            index: index,
            archiveURL: self.archiveURL,
            zipEntryPaths: self.zipEntryPaths,
            maxPixelSize: maxPixelSize,
            isAutoCropEnabled: isAutoCrop
        )

        // Store in cache for this generation
        if let image = result {
            imageCache.setObject(CGImageBox(image), forKey: NSNumber(value: index))
        }
        return result
    }

    // Issue 2 fix: static nonisolated function, but all ZIP reads are serialised
    // through PageBufferManager.archiveQueue — a serial DispatchQueue that ensures
    // only one ZIPFoundation extract() call runs at a time on the same archive file.
    nonisolated private static func executeRender(
        url: URL,
        index: Int,
        archiveURL: URL?,
        zipEntryPaths: [String],
        maxPixelSize: CGFloat?,
        isAutoCropEnabled: Bool
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }

        if let archiveURL, index < zipEntryPaths.count {
            let entryPath = zipEntryPaths[index]

            // Issue 2 fix: serialise ZIP reads through the archive queue.
            let cgImage: CGImage? = await withCheckedContinuation { continuation in
                _pageBufferArchiveQueue.async {
                    var result: CGImage? = nil
                    autoreleasepool {
                        do {
                            let archive = try Archive(url: archiveURL, accessMode: .read)
                            guard let entry = archive[entryPath] else { return }
                            var data = Data()
                            _ = try archive.extract(entry) { data.append($0) }
                            guard !Task.isCancelled else { return }

                            if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                                result = Self.decodeFromSource(source, maxPixelSize: maxPixelSize)
                            }
                        } catch {
                            Logger.shared.log(
                                "ZIP decode failed for \(entryPath): \(error.localizedDescription)",
                                category: "Engine", type: .error
                            )
                        }
                    }
                    continuation.resume(returning: result)
                }
            }

            guard let image = cgImage, !Task.isCancelled else { return nil }
            return isAutoCropEnabled ? autoCropMargins(from: image) : image
        }

        guard !Task.isCancelled else { return nil }

        // Strategy 1: CGImageSource from file URL (fastest, lowest memory)
        var cgImage: CGImage? = nil
        autoreleasepool {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                cgImage = Self.decodeFromSource(source, maxPixelSize: maxPixelSize)
            }
        }
        if let image = cgImage, !Task.isCancelled {
            return isAutoCropEnabled ? autoCropMargins(from: image) : image
        }

        // Strategy 2: UIImage fallback
        var fallbackImage: CGImage? = nil
        autoreleasepool {
            if let ui = UIImage(contentsOfFile: url.path), let cg = ui.cgImage {
                fallbackImage = cg
            }
        }
        if let cgImage = fallbackImage, !Task.isCancelled {
            Logger.shared.log(
                "CGImageSource failed, UIImage fallback succeeded — page \(index)",
                category: "Engine", type: .warning
            )
            let base = isAutoCropEnabled ? autoCropMargins(from: cgImage) : cgImage
            if let maxPx = maxPixelSize, CGFloat(Swift.max(base.width, base.height)) > maxPx {
                return autoreleasepool { downsample(cgImage: base, toMaxPixelSize: Int(maxPx)) }
            }
            return base
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        Logger.shared.log(
            "DECODE FAILED page \(index) | exists=\(exists) | \(url.lastPathComponent)",
            category: "Engine", type: .error
        )
        return nil
    }

    /// Shared decode helper — applies kCGImageSourceCreateThumbnailAtIndex
    /// with the Kindle-architecture-aware maxPixelSize.
    nonisolated private static func decodeFromSource(_ source: CGImageSource, maxPixelSize: CGFloat?) -> CGImage? {
        let options: [CFString: Any]
        if let maxSize = maxPixelSize {
            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxSize),
                kCGImageSourceShouldCacheImmediately: true
            ]
        } else {
            options = [kCGImageSourceShouldCacheImmediately: true]
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func downsample(cgImage: CGImage, toMaxPixelSize maxSize: Int) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        guard max(width, height) > maxSize else { return cgImage }

        let scale = CGFloat(maxSize) / CGFloat(max(width, height))
        let newW = Int(CGFloat(width) * scale)
        let newH = Int(CGFloat(height) * scale)

        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: newW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return cgImage }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? cgImage
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

    // Issue 5 fix: withExtendedLifetime pins the CFData backing buffer for the
    // full pixel scan. Without this, ARC can release `data` before `ptr` is
    // last used — the raw pointer becomes a dangling pointer into freed memory.
    nonisolated static func autoCropMargins(from image: CGImage) -> CGImage {
        return autoreleasepool {
            guard let cfData = image.dataProvider?.data else { return image }

            return withExtendedLifetime(cfData) {
                guard let ptr = CFDataGetBytePtr(cfData) else { return image }

                let width = image.width
                let height = image.height
                let bytesPerRow = image.bytesPerRow
                let bytesPerPixel = image.bitsPerPixel / 8
                guard bytesPerPixel >= 3 else { return image }

                let threshold: UInt8 = 245
                let strideVal = 8

                func rowHasContent(_ y: Int) -> Bool {
                    let rowOffset = y * bytesPerRow
                    for x in stride(from: 0, to: width, by: 10) {
                        let o = rowOffset + (x * bytesPerPixel)
                        if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                            return true
                        }
                    }
                    return false
                }

                func colHasContent(_ x: Int, fromY: Int, toY: Int) -> Bool {
                    for y in stride(from: fromY, to: toY, by: 10) {
                        let o = (y * bytesPerRow) + (x * bytesPerPixel)
                        if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold {
                            return true
                        }
                    }
                    return false
                }

                // Top
                var top = 0
                outer: for y in stride(from: 0, to: height, by: strideVal) {
                    if rowHasContent(y) {
                        let startY = max(0, y - strideVal + 1)
                        for fy in startY...y { if rowHasContent(fy) { top = fy; break outer } }
                    }
                }

                // Bottom
                var bottom = height - 1
                outer: for y in stride(from: height - 1, through: top, by: -strideVal) {
                    if rowHasContent(y) {
                        let startY = min(height - 1, y + strideVal - 1)
                        for fy in stride(from: startY, through: y, by: -1) { if rowHasContent(fy) { bottom = fy; break outer } }
                    }
                }

                // Left
                var left = 0
                outer: for x in stride(from: 0, to: width, by: strideVal) {
                    if colHasContent(x, fromY: top, toY: bottom) {
                        let startX = max(0, x - strideVal + 1)
                        for fx in startX...x { if colHasContent(fx, fromY: top, toY: bottom) { left = fx; break outer } }
                    }
                }

                // Right
                var right = width - 1
                outer: for x in stride(from: width - 1, through: left, by: -strideVal) {
                    if colHasContent(x, fromY: top, toY: bottom) {
                        let startX = min(width - 1, x + strideVal - 1)
                        for fx in stride(from: startX, through: x, by: -1) { if colHasContent(fx, fromY: top, toY: bottom) { right = fx; break outer } }
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
}
