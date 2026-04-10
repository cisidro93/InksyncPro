import Foundation
import SwiftUI

// MARK: - Result Types

struct StageResult {
    let staged: Int
    let skippedDuplicates: Int
    let duplicateURLs: [URL]
}

struct ImportSummary: Identifiable {
    let id = UUID()
    let seriesName: String
    let successCount: Int
    let failedURLs: [URL]
}

// MARK: - Persisted Queue Entry

private struct QueueEntry: Codable {
    let bookmarkData: Data
    let originalPath: String   // for display when bookmark can't resolve
}

// MARK: - ImportQueueManager

/// Accumulates comic file URLs before the user commits to "Import All".
/// Survives sheet dismissal and app backgrounding via bookmark persistence.
class ImportQueueManager: ObservableObject {
    static let shared = ImportQueueManager()
    private init() { loadPersistedQueue() }

    static let maxQueueSize = 500

    @Published var stagedURLs: [URL] = []
    @Published var isStagingFiles: Bool = false
    @Published var stagingProgress: (current: Int, total: Int)? = nil
    @Published var queueCapReached: Bool = false

    // MARK: - Smart Stage (primary entry point)

    /// Stages new files after dedup check. Returns what was skipped.
    /// Dedup order: (1) intra-batch dedup, (2) filename fast check,
    /// (3) chapter-key fast check, (4) SHA-256 hash check vs library.
    /// Security scope must NOT be held by caller — this function manages it.
    func stageWithDuplicateCheck(_ incomingURLs: [URL]) -> StageResult {
        // 1. Intra-batch dedup — remove duplicates within the incoming array itself
        var seenPaths = Set<String>()
        let dedupedIncoming = incomingURLs.filter { seenPaths.insert($0.path).inserted }

        // Take a thread-safe snapshot of the current queue for dedup logic
        var currentQueueSnapshot: [URL] = []
        DispatchQueue.main.sync {
            currentQueueSnapshot = self.stagedURLs
        }

        // 2. Fast pre-filters (no file I/O)
        let existingFilenames = Set(currentQueueSnapshot.map { $0.lastPathComponent })
        let existingChapterKeys: Set<String> = Set(currentQueueSnapshot.compactMap { url -> String? in
            let series = url.deletingLastPathComponent().lastPathComponent
            guard let ch = SeriesNameParser.chapterKey(from: url.lastPathComponent) else { return nil }
            return "\(series):\(ch)"
        })

        // 3. Hash-based library dedup is handled downstream in ImportOrchestrator.
        //    The queue manager focuses on fast intra-queue dedup only.
        //    Full SHA-256 dedup against the library happens at import time.

        var toStage: [URL] = []
        var dupes: [URL] = []
        let total = dedupedIncoming.count

        for (index, url) in dedupedIncoming.enumerated() {
            // Publish progress on main thread
            DispatchQueue.main.async {
                self.stagingProgress = (current: index + 1, total: total)
            }

            let filename = url.lastPathComponent
            let seriesFolder = url.deletingLastPathComponent().lastPathComponent

            // Fast filename check
            if existingFilenames.contains(filename) {
                dupes.append(url); continue
            }

            // Fast chapter-key check
            if let ch = SeriesNameParser.chapterKey(from: filename),
               existingChapterKeys.contains("\(seriesFolder):\(ch)") {
                dupes.append(url); continue
            }


            toStage.append(url)
        }

        // Apply queue size cap
        var currentCount = 0
        DispatchQueue.main.sync {
            currentCount = self.stagedURLs.count
        }
        
        let available = ImportQueueManager.maxQueueSize - currentCount
        if toStage.count > available {
            let overflow = toStage[available...]
            toStage = Array(toStage[..<available])
            dupes.append(contentsOf: overflow)
            DispatchQueue.main.async { self.queueCapReached = true }
        }

        DispatchQueue.main.sync {
            self.stagedURLs.append(contentsOf: toStage)
            self.persistQueue()
            self.stagingProgress = nil
        }

        return StageResult(
            staged: toStage.count,
            skippedDuplicates: dupes.count,
            duplicateURLs: dupes
        )
    }

    /// Force-stages URLs regardless of duplicate status.
    /// Called when user explicitly chooses "Import Anyway".
    func forceStage(_ urls: [URL]) {
        let available = ImportQueueManager.maxQueueSize - stagedURLs.count
        let toAdd = Array(urls.prefix(available))
        stagedURLs.append(contentsOf: toAdd)
        if toAdd.count < urls.count {
            queueCapReached = true
        }
        persistQueue()
    }

    // MARK: - Legacy Compatibility

    /// Simple stage by filename dedup only. Bridges old call sites.
    func stage(_ urls: [URL]) {
        let deduped = urls.filter { new in
            !stagedURLs.contains { $0.lastPathComponent == new.lastPathComponent }
        }
        let available = ImportQueueManager.maxQueueSize - stagedURLs.count
        let toAdd = Array(deduped.prefix(available))
        stagedURLs.append(contentsOf: toAdd)
        if toAdd.count < deduped.count {
            queueCapReached = true
        }
        persistQueue()
    }

    // MARK: - Standard Queue Operations

    func remove(at offsets: IndexSet) {
        stagedURLs.remove(atOffsets: offsets)
        persistQueue()
    }

    func clear() {
        stagedURLs.removeAll()
        queueCapReached = false
        UserDefaults.standard.removeObject(forKey: "importQueueBookmarks")
    }

    // MARK: - Bookmark Persistence

    private func persistQueue() {
        let entries: [QueueEntry] = stagedURLs.compactMap { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return QueueEntry(bookmarkData: data, originalPath: url.path)
        }
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: "importQueueBookmarks")
        }
    }

    private func loadPersistedQueue() {
        guard let data = UserDefaults.standard.data(forKey: "importQueueBookmarks"),
              let entries = try? JSONDecoder().decode([QueueEntry].self, from: data)
        else { return }

        var resolved: [URL] = []
        for entry in entries {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: entry.bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale {
                resolved.append(url)
            }
            // Stale bookmarks are silently pruned — file may have moved or been deleted
        }
        stagedURLs = resolved
    }
}
