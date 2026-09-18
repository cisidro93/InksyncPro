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

    nonisolated static func isGenericFolder(_ name: String) -> Bool {
        let genericContainers: Set<String> = [
            "downloads", "inbox", "tmp", "temp", "comics", "documents", "desktop", "manga", 
            "antigravity inksyncpro inbox", "inksyncpro inbox", "inksyncpro"
        ]
        let lower = name.lowercased()
        return genericContainers.contains(lower)
            || lower.contains("inbox")
            || lower.contains("staging")
            || lower.hasPrefix("folder_spider_")
            || lower.hasPrefix("com.apple")
    }

    // MARK: - Smart Stage (primary entry point)

    /// Stages new files after dedup check. Returns what was skipped.
    /// Stages new files into the import queue.
    /// Deduplication rules:
    /// 1. Intra-batch dedup: skips identical URLs selected multiple times in same batch.
    /// 2. In-queue dedup: skips files that are already staged in the active queue session.
    /// 3. Invariant: NEVER drop files based on chapter numbers (e.g. variant covers like Cover A, Cover B).
    /// 4. Invariant: Do NOT reject files from entering the staging queue because of library/database tracking.
    ///    The user has explicitly selected them to stage; ImportOrchestrator handles byte-level disk skipping safely at commit time.
    func stageWithDuplicateCheck(_ incomingURLs: [URL]) async -> StageResult {
        let currentSnapshot = stagedURLs
        
        // Build staged keys: (seriesFolder/filename) and full paths of items already in the active queue
        let existingStagedKeys = Set(currentSnapshot.map { url -> String in
            let series = url.deletingLastPathComponent().lastPathComponent.lowercased()
            return "\(series)/\(url.lastPathComponent.lowercased())"
        })
        let existingStagedPaths = Set(currentSnapshot.map { $0.path })

        // Move loop off the main thread
        let result = await Task.detached(priority: .userInitiated) { [existingStagedKeys, existingStagedPaths] () -> (toStage: [URL], dupes: [URL]) in
            var seenPaths = Set<String>()
            let dedupedIncoming = incomingURLs.filter { seenPaths.insert($0.path).inserted }

            var toStage: [URL] = []
            var dupes: [URL] = []

            for url in dedupedIncoming {
                let filename = url.lastPathComponent.lowercased()
                let seriesFolder = url.deletingLastPathComponent().lastPathComponent.lowercased()
                let stagedKey = "\(seriesFolder)/\(filename)"

                // Only skip if the exact file is ALREADY staged in the current queue session
                if existingStagedKeys.contains(stagedKey) || existingStagedPaths.contains(url.path) {
                    dupes.append(url)
                    continue
                }

                toStage.append(url)
            }
            return (toStage, dupes)
        }.value

        stagedURLs.append(contentsOf: result.toStage)
        stagingProgress = nil
        schedulePersist()

        return StageResult(
            staged: result.toStage.count,
            skippedDuplicates: result.dupes.count,
            duplicateURLs: result.dupes
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
            let optData = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            guard let data = optData else { return nil }
            return QueueEntry(bookmarkData: data, originalPath: url.path)
        }
        let optEncoded = try? JSONEncoder().encode(entries)
        if let encoded = optEncoded {
            UserDefaults.standard.set(encoded, forKey: "importQueueBookmarks")
        }
    }

    private func loadPersistedQueue() {
        guard let data = UserDefaults.standard.data(forKey: "importQueueBookmarks") else { return }
        let optEntries = try? JSONDecoder().decode([QueueEntry].self, from: data)
        guard let entries = optEntries else { return }

        Task {
            let resolved = await Task.detached(priority: .userInitiated) { () -> [URL] in
                var urls: [URL] = []
                for entry in entries {
                    var isStale = false
                    let optURL = try? URL(
                        resolvingBookmarkData: entry.bookmarkData,
                        options: .withoutUI,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    if let url = optURL, !isStale {
                        urls.append(url)
                    }
                }
                return urls
            }.value
            
            await MainActor.run {
                self.stagedURLs = resolved
            }
        }
    }
}
