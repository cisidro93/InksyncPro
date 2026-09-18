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

    /// Stages new files into the import queue with smart active-library duplicate detection.
    /// Deduplication rules:
    /// 1. Intra-batch dedup: skips identical file URLs selected multiple times in the same selection batch.
    /// 2. In-queue dedup: skips files that are already staged in the active queue session.
    /// 3. Active Library dedup: checks what files are ACTIVELY present on physical disk in the app library
    ///    (matching by same series + filename, or same file size + filename).
    /// 4. Invariant: NEVER drop files based on chapter numbers (e.g. variant covers like Cover A, Cover B
    ///    have different filenames/sizes and are preserved with 100% fidelity).
    /// 5. Detected duplicates are cleanly separated into `duplicateURLs` so the UI can prompt the user
    ///    to "Skip Duplicates" or "Import Anyway", preventing duplicate clutter in the library.
    func stageWithDuplicateCheck(_ incomingURLs: [URL]) async -> StageResult {
        let currentSnapshot = stagedURLs
        
        // Build staged keys: (seriesFolder/filename) and full paths of items already in the active queue
        let existingStagedKeys = Set(currentSnapshot.map { url -> String in
            let series = url.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "\(series)/\(url.lastPathComponent.lowercased())"
        })
        let existingStagedPaths = Set(currentSnapshot.map { $0.path })
        let existingStagedSizes = Set(currentSnapshot.compactMap { url -> String? in
            let series = url.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !Self.isGenericFolder(series) && !series.isEmpty else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size > 0 else { return nil }
            return "\(series)||\(size)"
        })

        // Build active library lookup:
        // Key 1: activeSeriesKeys ("series/filename")
        // Key 2: activeSeriesSizes ("series||fileSize") -> catches renamed duplicates (e.g. "1.1" matching "1" by size)
        // Key 3: activeFingerprints ("fileSize||filename")
        let (activeSeriesKeys, activeSeriesSizes, activeFingerprints) = await MainActor.run {
            var sKeys = Set<String>()
            var sSizes = Set<String>()
            var fingerprints = Set<String>()
            let fm = FileManager.default
            for item in LibraryService.shared.items {
                // Ensure the file is ACTIVELY on physical disk.
                // If it was deleted on disk, it is a ghost entry and must NOT block re-importing!
                guard fm.fileExists(atPath: item.url.path) else { continue }
                
                let series = (item.metadata.series ?? item.url.deletingLastPathComponent().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let fn = item.url.lastPathComponent.lowercased()
                if !Self.isGenericFolder(series) && !series.isEmpty {
                    sKeys.insert("\(series)/\(fn)")
                    if item.fileSize > 0 {
                        sSizes.insert("\(series)||\(item.fileSize)")
                    }
                }
                if item.fileSize > 0 {
                    fingerprints.insert("\(item.fileSize)||\(fn)")
                }
            }
            return (sKeys, sSizes, fingerprints)
        }

        // Move loop off the main thread
        let result = await Task.detached(priority: .userInitiated) { [existingStagedKeys, existingStagedPaths, existingStagedSizes, activeSeriesKeys, activeSeriesSizes, activeFingerprints] () -> (toStage: [URL], dupes: [URL]) in
            var seenPaths = Set<String>()
            let dedupedIncoming = incomingURLs.filter { seenPaths.insert($0.path).inserted }

            var batchSeriesFiles = Set<String>()
            var batchSeriesSizes = Set<String>()

            var toStage: [URL] = []
            var dupes: [URL] = []

            for url in dedupedIncoming {
                let filename = url.lastPathComponent.lowercased()
                let seriesFolder = url.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isGeneric = Self.isGenericFolder(seriesFolder)
                let stagedKey = "\(seriesFolder)/\(filename)"
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let seriesSizeKey = (!isGeneric && !seriesFolder.isEmpty && fileSize > 0) ? "\(seriesFolder)||\(fileSize)" : ""

                // 1. Check if already staged in current queue session or earlier in this batch (exact file)
                if existingStagedKeys.contains(stagedKey) || existingStagedPaths.contains(url.path) || batchSeriesFiles.contains(stagedKey) {
                    dupes.append(url)
                    continue
                }

                // 2. Check if already actively in the app library under the same series by filename
                if !isGeneric && !seriesFolder.isEmpty && activeSeriesKeys.contains(stagedKey) {
                    dupes.append(url)
                    continue
                }

                // 3. Check for renamed duplicate copies in the same series (e.g. "1.1" or "Issue 1 (1)" matching "1" by size)
                if !seriesSizeKey.isEmpty && (activeSeriesSizes.contains(seriesSizeKey) || existingStagedSizes.contains(seriesSizeKey) || batchSeriesSizes.contains(seriesSizeKey)) {
                    dupes.append(url)
                    continue
                }

                // 4. Check if exact file (matching byte-size and filename) actively exists in library
                if fileSize > 0 && activeFingerprints.contains("\(fileSize)||\(filename)") {
                    dupes.append(url)
                    continue
                }

                toStage.append(url)
                batchSeriesFiles.insert(stagedKey)
                if !seriesSizeKey.isEmpty {
                    batchSeriesSizes.insert(seriesSizeKey)
                }
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
