import Foundation

/// Enterprise diagnostic logger for the Reader Engine (EBook, Comic, PDF).
/// Outputs directly to `Logger.shared` under Category "Reader".
enum ReaderEngineDiagnosticLogger {
    
    static func logChapterOpen(bookTitle: String, chapterTitle: String, spineIndex: Int, totalSpineItems: Int, isLandscape: Bool) {
        let msg = """
        📖 [READER CHAPTER LOADED]
        📚 Book: \(bookTitle)
        📑 Chapter [\(spineIndex + 1)/\(totalSpineItems)]: \(chapterTitle)
        📐 Orientation: \(isLandscape ? "Landscape Spreads" : "Portrait Single")
        """
        Logger.shared.log(msg, category: "Reader", type: .info)
    }
    
    static func logPrecache(hit: Bool, pageIndex: Int, cachedPagesCount: Int) {
        let status = hit ? "✅ HIT" : "🌀 MISS (Generating Snapshot)"
        Logger.shared.log("Precache \(status) — Page \(pageIndex) (Active Snapshots: \(cachedPagesCount))", category: "Reader", type: .debug)
    }
    
    static func logNavigation(source: String, targetPageIndex: Int, anchorID: String? = nil) {
        let anchorStr = anchorID != nil ? " → Anchor '#\(anchorID!)'" : ""
        Logger.shared.log("🔗 Navigated via \(source) → Page \(targetPageIndex)\(anchorStr)", category: "Reader", type: .info)
    }
    
    static func logRenderTiming(phase: String, elapsedMs: Double) {
        let icon = elapsedMs > 100 ? "⚠️" : "⚡"
        Logger.shared.log("\(icon) [READER PERFORMANCE] \(phase) completed in \(String(format: "%.2f", elapsedMs))ms", category: "Reader", type: elapsedMs > 250 ? .warning : .info)
    }
    
    static func logMemoryPurge(reason: String, cachedPagesFreed: Int) {
        Logger.shared.log("🧹 [MEMORY PURGE] \(reason) — Purged \(cachedPagesFreed) precached snapshots", category: "Reader", type: .warning)
    }
}
