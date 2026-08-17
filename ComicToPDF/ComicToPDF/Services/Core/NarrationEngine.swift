import Foundation
import Vision
import UIKit
import SwiftUI

// MARK: - PageOCREngine
//
// Layout-aware OCR/text extraction cache for the Comic Dialogue Lens.
//
// Pipeline:
//  1. Vision VNRecognizeTextRequest extracts text from each comic page image
//  2. Text is sorted into reading order (top-left → bottom-right with manga flip support)
//  3. All Vision work is done off the MainActor (Task.detached, background QoS)
//
// Design decisions:
//  • Actor isolation: PageOCREngine is @MainActor so all @Published mutations
//    are safe. Vision work is Task.detached so it never blocks the UI thread.
//  • Debounced page caching: text is OCR'd ahead of time (±2 pages prefetch)
//    so retrieving is instant with zero perceptible latency.
//  • Manga RTL: when isMangaMode is true, text blocks are sorted right-to-left
//    so speech/dialogue follows the correct reading direction.

@MainActor
final class PageOCREngine: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isOCRing: Bool = false
    @Published private(set) var currentPageIndex: Int = 0

    // MARK: - Configuration

    var isMangaMode: Bool = false

    // MARK: - Private

    private var ocrCache: [Int: String] = [:]       // page index → extracted text
    private var textBlocksCache: [Int: [TextBlock]] = [:] // page index -> text blocks
    private var ocrTasks: [Int: Task<Void, Never>] = [:]
    private var totalPages: Int = 0
    private var imageProvider: ((Int) -> UIImage?)? = nil  // closure from the reader

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Connect the engine to a comic reader's image cache.
    func connect(totalPages: Int, imageProvider: @escaping (Int) -> UIImage?) {
        self.totalPages = totalPages
        self.imageProvider = imageProvider
        ocrCache.removeAll()
        textBlocksCache.removeAll()
        ocrTasks.values.forEach { $0.cancel() }
        ocrTasks.removeAll()
    }

    /// Fetch or compute text blocks for a page, caching the result.
    func fetchTextBlocks(for pageIndex: Int) async -> [TextBlock] {
        guard totalPages > 0, pageIndex >= 0, pageIndex < totalPages else { return [] }
        if let cached = textBlocksCache[pageIndex] {
            return cached
        }
        isOCRing = true
        let blocks = await performOCRAndCache(pageIndex: pageIndex)
        isOCRing = false
        return blocks
    }

    /// Pre-warm OCR cache for a page.
    func prewarmOCR(for pageIndex: Int) {
        guard totalPages > 0, pageIndex >= 0, pageIndex < totalPages else { return }
        currentPageIndex = pageIndex
        prefetchOCR(around: pageIndex)
    }

    // MARK: - OCR (Vision)

    nonisolated private func performOCRAndCache(pageIndex: Int) async -> [TextBlock] {
        let (image, isManga) = await MainActor.run(body: { (self.imageProvider?(pageIndex), self.isMangaMode) })
        guard let image = image else { return [] }

        guard !Task.isCancelled else { return [] }

        let blocks = await PageOCRService.shared.performOCR(on: image)

        guard !Task.isCancelled else { return [] }

        // Sort observations into reading order
        // Standard: top-to-bottom, then left-to-right within a band
        // Manga RTL: top-to-bottom, then right-to-left within a band
        let bandHeight: CGFloat = 0.08   // ~8% of image height per band
        let sorted = blocks.sorted { lhs, rhs in
            let lhsBox = lhs.boundingBox
            let rhsBox = rhs.boundingBox
            // Vision boxes are bottom-origin so we invert Y for sorting
            let lhsRow = Int((1.0 - lhsBox.midY) / bandHeight)
            let rhsRow = Int((1.0 - rhsBox.midY) / bandHeight)
            if lhsRow != rhsRow { return lhsRow < rhsRow }
            // Same row band — sort by X (RTL for manga, LTR for standard)
            return isManga ? (lhsBox.midX > rhsBox.midX) : (lhsBox.midX < rhsBox.midX)
        }

        let text = sorted.compactMap { $0.text }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")

        await MainActor.run {
            self.textBlocksCache[pageIndex] = sorted
            self.ocrCache[pageIndex] = text
        }

        return sorted
    }

    // MARK: - Prefetch

    private func prefetchOCR(around pageIndex: Int) {
        guard totalPages > 0 else { return }
        let lower = max(0, pageIndex - 1)
        let upper = min(totalPages - 1, pageIndex + 2)
        guard lower <= upper else { return }
        let window = lower...upper
        
        // Cancel and remove out-of-window prefetch tasks to save CPU cycles
        let outOfWindowKeys = ocrTasks.keys.filter { !window.contains($0) }
        for i in outOfWindowKeys {
            ocrTasks[i]?.cancel()
            ocrTasks.removeValue(forKey: i)
        }
        
        for i in window {
            guard ocrCache[i] == nil, ocrTasks[i] == nil else { continue }
            let task = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                _ = await self.performOCRAndCache(pageIndex: i)
                _ = await MainActor.run { [weak self] in
                    self?.ocrTasks.removeValue(forKey: i)
                }
            }
            ocrTasks[i] = task
        }
    }
}
