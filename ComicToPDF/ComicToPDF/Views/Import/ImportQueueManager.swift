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
/// @MainActor: all @Published mutations happen on the main actor, eliminating
/// the previous DispatchQueue.main.sync deadlock risk when called from background tasks.
@MainActor
class ImportQueueManager: ObservableObject {
    static let shared = ImportQueueManager()
    private init() { loadPersistedQueue() }

    @Published var stagedURLs: [URL] = []
    @Published var isStagingFiles: Bool = false
    @Published var stagingProgress: (current: Int, total: Int)? = nil

    // Debounce token — coalesces multiple rapid persist calls into one disk write.
    private var persistTask: Task<Void, Never>?

    // MARK: - Smart Stage (primary entry point)

    /// Stages new files after dedup check. Returns what was skipped.
    /// Dedup order: (1) intra-batch dedup, (2) filename fast check,
    /// (3) chapter-key fast check, (4) SHA-256 hash check vs library.
    func stageWithDuplicateCheck(_ incomingURLs: [URL]) -> StageResult {
        // 1. Intra-batch dedup — remove duplicates within the incoming array itself
        var seenPaths = Set<String>()
        let dedupedIncoming = incomingURLs.filter { seenPaths.insert($0.path).inserted }

        // @MainActor guarantees safe direct read — no .sync needed
        let currentQueueSnapshot = stagedURLs

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
            // Safe direct mutation — we are @MainActor
            stagingProgress = (current: index + 1, total: total)

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

        stagedURLs.append(contentsOf: toStage)
        stagingProgress = nil
        schedulePersist()   // debounced — won't write on every file during batch imports

        return StageResult(
            staged: toStage.count,
            skippedDuplicates: dupes.count,
            duplicateURLs: dupes
        )
    }

    /// Force-stages URLs regardless of duplicate status.
    /// Called when user explicitly chooses "Import Anyway".
    func forceStage(_ urls: [URL]) {
        stagedURLs.append(contentsOf: urls)
        schedulePersist()
    }

    // MARK: - Legacy Compatibility

    /// Simple stage by filename dedup only. Bridges old call sites.
    func stage(_ urls: [URL]) {
        let deduped = urls.filter { new in
            !stagedURLs.contains { $0.lastPathComponent == new.lastPathComponent }
        }
        stagedURLs.append(contentsOf: deduped)
        schedulePersist()
    }

    // MARK: - Standard Queue Operations

    func remove(at offsets: IndexSet) {
        stagedURLs.remove(atOffsets: offsets)
        schedulePersist()
    }

    func clear() {
        stagedURLs.removeAll()
        persistTask?.cancel()
        UserDefaults.standard.removeObject(forKey: "importQueueBookmarks")
    }

    // MARK: - Debounced Bookmark Persistence

    /// Schedules a disk write 500 ms after the last call.
    /// During a 500-file batch import this fires exactly once after
    /// the loop finishes, instead of 500 times.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500 ms
            guard !Task.isCancelled, let self else { return }
            self.persistQueue()
        }
    }

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
