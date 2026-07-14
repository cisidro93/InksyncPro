import Foundation
import SwiftUI

struct CleanupItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let displayName: String
    let fileSizeBytes: Int64
    let category: CleanupCategory
}

enum CleanupCategory: String, CaseIterable, Sendable {
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
        let total = await Task.detached(priority: .background) {
            let temp = await Self.scanTempDirectory()
            let cache = await Self.scanSourceCache()
            let orphaned = await Self.scanOrphanedConverted()
            return (temp + cache + orphaned).reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        }.value

        passiveReclaimableBytes = total
    }

    // MARK: - Full Scan (manual trigger from Settings)

    func scanForCleanup() async {
        isScanning = true
        scanResults = [:]

        let resultTuple = await Task.detached(priority: .userInitiated) {
            let temp = await Self.scanTempDirectory()
            let cache = await Self.scanSourceCache()
            let orphaned = await Self.scanOrphanedConverted()

            var results: [CleanupCategory: [CleanupItem]] = [:]
            if !temp.isEmpty     { results[.orphanedTemp] = temp }
            if !cache.isEmpty    { results[.sourceCache] = cache }
            if !orphaned.isEmpty { results[.orphanedConverted] = orphaned }

            let total = (temp + cache + orphaned).reduce(Int64(0)) { $0 + $1.fileSizeBytes }
            return (results, total)
        }.value

        scanResults = resultTuple.0
        totalReclaimableBytes = resultTuple.1
        isScanning = false
    }

    // MARK: - Scanners

    private static func scanTempDirectory() async -> [CleanupItem] {
        let tmp = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let oneHourAgo = Date().addingTimeInterval(-3600)
        let comicExtensions: Set<String> = ["pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip"]

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

    private static func scanSourceCache() async -> [CleanupItem] {
        let cacheDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceCache")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let oneHourAgo = Date().addingTimeInterval(-3600)
        let comicExtensions: Set<String> = ["pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip"]
        return contents.compactMap { url -> CleanupItem? in
            guard comicExtensions.contains(url.pathExtension.lowercased()),
                  let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
                  let created = attrs.creationDate,
                  created < oneHourAgo,
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

    private static func scanOrphanedConverted() async -> [CleanupItem] {
        let documentsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]

        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: documentsDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let activePDFs = await LibraryDatabaseService.shared.load()
        let activeRelativePaths = Set(activePDFs.map { pdf -> String in
            let path = pdf.url.path
            if let range = path.range(of: "/Documents/") {
                return "Documents/" + String(path[range.upperBound...])
            }
            if let range = path.range(of: "/InksyncVault/Inbox/") {
                return "Inbox/" + String(path[range.upperBound...])
            }
            return pdf.url.lastPathComponent
        })

        let comicExtensions: Set<String> = ["pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip"]
        var orphanedItems: [CleanupItem] = []

        while let url = enumerator.nextObject() as? URL {
            let path = url.path
            
            if path.contains("/SourceCache/") {
                continue
            }

            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDir = attrs.isDirectory, !isDir,
                  comicExtensions.contains(url.pathExtension.lowercased())
            else { continue }

            let filename = url.lastPathComponent
            guard filename != "Welcome.cbz" else { continue }

            let relPath: String
            if let range = path.range(of: "/Documents/") {
                relPath = "Documents/" + String(path[range.upperBound...])
            } else {
                relPath = filename
            }

            if !activeRelativePaths.contains(relPath), let size = attrs.fileSize {
                orphanedItems.append(CleanupItem(
                    url: url,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    fileSizeBytes: Int64(size),
                    category: .orphanedConverted
                ))
            }
        }

        return orphanedItems
    }

    // MARK: - Deletion (explicit user action only)

    func delete(_ items: [CleanupItem]) async -> Int {
        isScanning = true
        
        let deletedCount = await Task.detached(priority: .userInitiated) {
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
            return deleted
        }.value

        await scanForCleanup()
        passiveReclaimableBytes = totalReclaimableBytes
        return deletedCount
    }

    func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Automatically scans and purges temp/cache directories if free space drops below 1.0 GB.
    func autoCleanupIfStorageLow() async {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: documentsDir.path),
              let freeSpace = attrs[.systemFreeSize] as? Int64 else { return }
        
        let oneGigabyte: Int64 = 1 * 1024 * 1024 * 1024
        
        if freeSpace < oneGigabyte {
            Logger.shared.log("Storage space is low (\(ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)) < 1.0 GB). Running automatic sandbox cleanup...", category: "System", type: .warning)
            
            // Scan for items that are safe to delete passively
            let tempItems = await Self.scanTempDirectory()
            let cacheItems = await Self.scanSourceCache()
            
            let itemsToDelete = tempItems + cacheItems
            if !itemsToDelete.isEmpty {
                let deletedCount = await Task.detached(priority: .background) {
                    var deleted = 0
                    for item in itemsToDelete {
                        do {
                            try FileManager.default.removeItem(at: item.url)
                            deleted += 1
                        } catch {}
                    }
                    return deleted
                }.value
                
                Logger.shared.log("Auto-cleanup completed: deleted \(deletedCount) temporary and cached items to reclaim storage.", category: "System", type: .success)
                
                // Refresh local reclaimable properties
                await scanForCleanup()
            }
        }
    }
}
