import Foundation
import CoreGraphics
import CoreImage
import Combine
import ImageIO

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
    private var renderTask: Task<Void, Never>?
    /// Incremented every time setup() is called. Any decode that finishes after a new
    /// setup() has started is stale — it must not write to any @Published property.
    private var generation: Int = 0

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
        lockedRect = .full
        currentImage = nil
        nextImage = nil
        prevImage = nil
        currentSpread = nil
        nextSpread = nil
        prevSpread = nil
    }

    func updateViewport(rect: NormalizedRect) {
        lockedRect = rect
    }

    // MARK: - Single Page Render

    func render(pageIndex: Int, bounds: CGSize) {
        renderTask?.cancel()
        let gen = generation          // capture — guards against stale writes
        renderTask = Task {
            self.isLoading = true

            async let current = renderPage(at: pageIndex)
            async let next    = renderPage(at: pageIndex + 1)
            async let prev    = renderPage(at: pageIndex - 1)

            let (cImage, nImage, pImage) = await (current, next, prev)
            // Discard results if cancelled OR if a newer setup() has since started
            guard !Task.isCancelled, self.generation == gen else { return }

            self.currentImage = cImage
            self.nextImage    = nImage
            self.prevImage    = pImage
            self.isLoading    = false

            emitNearingEndIfNeeded(at: pageIndex)
        }
    }

    // MARK: - Dual Page Render

    /// Render a spread window around `leadIndex` (the left page of the current spread).
    /// `isMangaMode` controls which physical page index maps to left vs right.
    func renderDual(leadIndex: Int, pages allPages: [URL], isMangaMode: Bool) {
        renderTask?.cancel()
        let gen = generation          // capture — guards against stale writes
        renderTask = Task {
            self.isLoading = true
            self.decodeProgress = 0.0

            // Build the three spread pairs: prev, current, next
            let curPair  = buildSpreadPair(leadIndex: leadIndex, allPages: allPages, isMangaMode: isMangaMode)
            let prevPair = buildSpreadPair(leadIndex: leadIndex - 2, allPages: allPages, isMangaMode: isMangaMode)
            let nextPair = buildSpreadPair(leadIndex: leadIndex + 2, allPages: allPages, isMangaMode: isMangaMode)

            // Decode all 6 images concurrently — update progress as each resolves
            async let curL  = renderPage(at: curPair.leftIndex)
            async let curR  = renderPage(at: curPair.rightIndex)
            async let prevL = renderPage(at: prevPair.leftIndex)
            async let prevR = renderPage(at: prevPair.rightIndex)
            async let nextL = renderPage(at: nextPair.leftIndex)
            async let nextR = renderPage(at: nextPair.rightIndex)

            // Resolve current pair first (visible immediately) then background pairs
            let cL = await curL;  self.decodeProgress = 1/6
            let cR = await curR;  self.decodeProgress = 2/6
            // Publish partial state so first spread appears before prev/next finish
            // Guard generation before every write — a new setup() may have arrived.
            if !Task.isCancelled, self.generation == gen {
                self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cL, rightImage: cR)
                self.currentImage  = cL ?? cR
                self.isLoading     = false  // UI unlocks here
            }
            let pL = await prevL; self.decodeProgress = 3/6
            let pR = await prevR; self.decodeProgress = 4/6
            let nL = await nextL; self.decodeProgress = 5/6
            let nR = await nextR; self.decodeProgress = 6/6
            guard !Task.isCancelled, self.generation == gen else { return }

            self.currentSpread = SpreadPair(leftIndex: curPair.leftIndex, rightIndex: curPair.rightIndex, leftImage: cL, rightImage: cR)
            self.prevSpread    = SpreadPair(leftIndex: prevPair.leftIndex, rightIndex: prevPair.rightIndex, leftImage: pL, rightImage: pR)
            self.nextSpread    = SpreadPair(leftIndex: nextPair.leftIndex, rightIndex: nextPair.rightIndex, leftImage: nL, rightImage: nR)

            // Keep single-page slots populated so switching back to single-page mode doesn't flash blank
            self.currentImage = cL ?? cR
            self.nextImage    = nL ?? nR
            self.prevImage    = pL ?? pR

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

    private func renderPage(at index: Int?) async -> CGImage? {
        guard let index = index, index >= 0, index < pageURLs.count else { return nil }
        let url = pageURLs[index]

        return await Task.detached(priority: .userInitiated) {
            // Strategy 1: CGImageSource (fastest, best memory usage)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let cropEnabled = await MainActor.run { self.isAutoCropEnabled }
                return cropEnabled ? Self.autoCropMargins(from: cgImage) : cgImage
            }

            // Strategy 2: UIImage fallback (different OS codec path — handles some edge cases
            // where CGImageSource returns nil for valid JPEGs on certain iOS versions)
            if let uiImage = UIImage(contentsOfFile: url.path), let cgImage = uiImage.cgImage {
                await MainActor.run {
                    Logger.shared.log(
                        "PageBufferManager: CGImageSource failed but UIImage succeeded for page \(index) — \(url.lastPathComponent)",
                        category: "Engine", type: .warning
                    )
                }
                let cropEnabled = await MainActor.run { self.isAutoCropEnabled }
                return cropEnabled ? Self.autoCropMargins(from: cgImage) : cgImage
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
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return image }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return image }

        let threshold: UInt8 = 245

        var top = 0
        outerTop: for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: 10) {
                let o = rowOffset + (x * bytesPerPixel)
                if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold { break outerTop }
            }
            top = y
        }

        var bottom = height - 1
        outerBottom: for y in stride(from: height - 1, through: 0, by: -1) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: 10) {
                let o = rowOffset + (x * bytesPerPixel)
                if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold { break outerBottom }
            }
            bottom = y
        }

        var left = 0
        outerLeft: for x in 0..<width {
            for y in stride(from: top, to: bottom, by: 10) {
                let o = (y * bytesPerRow) + (x * bytesPerPixel)
                if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold { break outerLeft }
            }
            left = x
        }

        var right = width - 1
        outerRight: for x in stride(from: width - 1, through: 0, by: -1) {
            for y in stride(from: top, to: bottom, by: 10) {
                let o = (y * bytesPerRow) + (x * bytesPerPixel)
                if ptr[o] < threshold || ptr[o+1] < threshold || ptr[o+2] < threshold { break outerRight }
            }
            right = x
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
