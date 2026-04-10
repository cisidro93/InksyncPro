import Foundation
import SwiftUI

struct CleanupItem: Identifiable {
    let id = UUID()
    let url: URL
    let displayName: String
    let fileSizeBytes: Int64
    let category: CleanupCategory
}

enum CleanupCategory: String, CaseIterable {
    case orphanedTemp       = "Orphaned Temp Files"
    case sourceCache        = "Source Cache Copies"
    case orphanedConverted  = "Converted Files (No Library Entry)"

    var description: String {
        switch self {
        case .orphanedTemp:
            return "Incomplete conversion leftovers. Always safe to remove."
        case .sourceCache:
            return "CBZ/CBR copies made during import. Your originals in Downloads are untouched."
        case .orphanedConverted:
            return "Converted files whose library entries have been deleted. Safe to remove."
        }
    }

    var systemImage: String {
        switch self {
        case .orphanedTemp:     return "exclamationmark.triangle"
        case .sourceCache:      return "doc.on.doc"
        case .orphanedConverted: return "doc.badge.minus"
        }
    }
}

@MainActor
class SandboxCleanupManager: ObservableObject {
    static let shared = SandboxCleanupManager()
    private init() {}

    @Published var isScanning = false
    @Published var scanResults: [CleanupCategory: [CleanupItem]] = [:]
    @Published var totalReclaimableBytes: Int64 = 0
    @Published var passiveReclaimableBytes: Int64 = 0

    // MARK: - Passive Scan (app launch, no deletion)

    func passiveScan() async {
        let temp = await scanTempDirectory()
        let cache = await scanSourceCache()
        let orphaned = await scanOrphanedConverted()
        let total = (temp + cache + orphaned).reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        passiveReclaimableBytes = total
    }

    // MARK: - Full Scan (manual trigger from Settings)

    func scanForCleanup() async {
        isScanning = true
        scanResults = [:]

        let temp = await scanTempDirectory()
        let cache = await scanSourceCache()
        let orphaned = await scanOrphanedConverted()

        var results: [CleanupCategory: [CleanupItem]] = [:]
        if !temp.isEmpty     { results[.orphanedTemp] = temp }
        if !cache.isEmpty    { results[.sourceCache] = cache }
        if !orphaned.isEmpty { results[.orphanedConverted] = orphaned }

        scanResults = results
        totalReclaimableBytes = (temp + cache + orphaned).reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        isScanning = false
    }

    // MARK: - Scanners

    private func scanTempDirectory() async -> [CleanupItem] {
        let tmp = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let oneHourAgo = Date().addingTimeInterval(-3600)
        let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "zip", "pdf", "epub"]

        return contents.compactMap { url -> CleanupItem? in
            guard comicExtensions.contains(url.pathExtension.lowercased()),
                  let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
                  let created = attrs.creationDate,
                  created < oneHourAgo,
                  let size = attrs.fileSize
            else { return nil }
            return CleanupItem(
                url: url,
                displayName: url.lastPathComponent,
                fileSizeBytes: Int64(size),
                category: .orphanedTemp
            )
        }
    }

    private func scanSourceCache() async -> [CleanupItem] {
        let cacheDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceCache")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "zip"]
        return contents.compactMap { url -> CleanupItem? in
            guard comicExtensions.contains(url.pathExtension.lowercased()),
                  let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = attrs.fileSize
            else { return nil }
            return CleanupItem(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                fileSizeBytes: Int64(size),
                category: .sourceCache
            )
        }
    }

    private func scanOrphanedConverted() async -> [CleanupItem] {
        // Scans Documents/ for comic files that have no matching library entry.
        // A file is "orphaned" if no ConvertedPDF record references its filename.
        let documentsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: documentsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        // Build the set of active filenames from the library.
        // ConversionManager is on MainActor — we dispatch to read it.
        let activeFilenames: Set<String> = await MainActor.run {
            // Access via NotificationCenter pattern since we don't hold a reference.
            // For the initial implementation, we'll scan the last-saved library JSON.
            let libraryURL = documentsDir.appendingPathComponent("library.json")
            guard let data = try? Data(contentsOf: libraryURL),
                  let pdfs = try? JSONDecoder().decode([ConvertedPDF].self, from: data) else {
                return Set()
            }
            return Set(pdfs.map { $0.url.lastPathComponent })
        }

        let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip"]
        return contents.compactMap { url -> CleanupItem? in
            let filename = url.lastPathComponent
            guard comicExtensions.contains(url.pathExtension.lowercased()),
                  !activeFilenames.contains(filename),
                  filename != "Welcome.cbz",  // Don't flag the welcome file
                  let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = attrs.fileSize
            else { return nil }
            return CleanupItem(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                fileSizeBytes: Int64(size),
                category: .orphanedConverted
            )
        }
    }

    // MARK: - Deletion (explicit user action only)

    func delete(_ items: [CleanupItem]) async -> Int {
        var deleted = 0
        for item in items {
            do {
                try FileManager.default.removeItem(at: item.url)
                deleted += 1
            } catch {
                Logger.shared.log(
                    "Cleanup delete failed for \(item.displayName): \(error)",
                    category: "Cleanup", type: .error
                )
            }
        }
        await scanForCleanup()
        passiveReclaimableBytes = totalReclaimableBytes
        return deleted
    }

    func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
