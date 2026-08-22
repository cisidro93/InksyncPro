import Foundation
import Combine
import UIKit

// MARK: - SharedImportCoordinator
//
// Single-responsibility actor that owns the entire shared-import pipeline:
//
//  1.  Share Extension writes files into AppGroup/<any>/ShareStaging/ or
//      AppGroup/<any>/Inbox/  and sets `pendingShareImportTimestamp` in each
//      AppGroup UserDefaults suite.
//
//  2.  On foreground / URL open / AppDelegate callback, the host app calls
//      `coordinateImport(source:)`.  This actor moves every staged file into
//      the canonical InksyncVault/Inbox/ and resolves the final filenames.
//
//  3.  It publishes `ingestedFileNames` so ContentView can auto-select the
//      book after a scan.
//
// Why an actor?
//  - FileManager operations are not concurrency-safe from multiple callers.
//  - The polling retry loop must be serialized so we never double-move a file.

@MainActor
final class SharedImportCoordinator: ObservableObject {

    static let shared = SharedImportCoordinator()

    // UI-observable set of filenames that were just ingested during this launch.
    @Published private(set) var pendingAutoSelectFilenames: Set<String> = []

    private let appGroupIDs = [
        "group.com.antigravity.ComicToPDF",
        "group.com.antigravity.inksync",
        "group.com.antigravity.InksyncPro"
    ]

    private let supportedExtensions: Set<String> = [
        "pdf", "epub", "cbz", "cbr", "cb7", "cbt"
    ]

    private var isIngesting = false

    // MARK: - Entry Points

    /// Called by ContentView's willEnterForeground observer, AppDelegate URL handler,
    /// and the `inksyncpro://` deep-link handler. Safe to call multiple times — it
    /// debounces internally.
    func coordinateImport(retryCount: Int = 3, retryDelaySeconds: Double = 0.8) {
        guard !isIngesting else { return }
        isIngesting = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ingestedNames = await self.ingestWithRetry(maxAttempts: retryCount, retryDelay: retryDelaySeconds)
            await MainActor.run {
                for name in ingestedNames {
                    self.pendingAutoSelectFilenames.insert(name)
                }
                self.clearPendingShareFlags()
                self.isIngesting = false
            }
        }
    }

    /// Called when a direct file:// URL is handed to the app (Open With, Files.app, AirDrop).
    /// The caller must have already copied the file to InksyncVault/Inbox.
    func registerDirectlyOpenedFile(at url: URL) {
        let filename = url.lastPathComponent
        if !filename.isEmpty {
            pendingAutoSelectFilenames.insert(filename)
        }
    }

    // MARK: - Private: Retry Loop

    nonisolated private func ingestWithRetry(maxAttempts: Int, retryDelay: Double) async -> [String] {
        var allIngested: [String] = []
        for attempt in 1...maxAttempts {
            let names = await moveStagedFilesToInbox()
            if !names.isEmpty {
                allIngested.append(contentsOf: names)
                Logger.shared.log(
                    "SharedImportCoordinator: Ingested \(names.count) file(s) on attempt \(attempt)",
                    category: "Import", type: .success
                )
                return allIngested
            }
            // No files found yet — the extension process may still be writing.
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        Logger.shared.log(
            "SharedImportCoordinator: No staged files found after \(maxAttempts) attempts — " +
            "will rely on next foreground scan.",
            category: "Import", type: .warning
        )
        return allIngested
    }

    // MARK: - Private: File Movement

    nonisolated private func moveStagedFilesToInbox() async -> [String] {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        var ingestedFilenames: [String] = []
        var visitedContainers: Set<URL> = []

        for groupID in appGroupIDs {
            guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID),
                  !visitedContainers.contains(container)
            else { continue }
            visitedContainers.insert(container)

            let stagingDirs = [
                container.appendingPathComponent("ShareStaging"),
                container.appendingPathComponent("Inbox"),
                container.appendingPathComponent("PendingConversions")
            ]

            for stagingDir in stagingDirs {
                guard let enumerator = fm.enumerator(
                    at: stagingDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                          !isDir.boolValue
                    else { continue }

                    let ext = fileURL.pathExtension.lowercased()

                    // Delete manifest files, they are not library items.
                    if ext == "json" || fileURL.lastPathComponent.hasSuffix(".manifest.json") {
                        try? fm.removeItem(at: fileURL)
                        continue
                    }

                    // Map zip/rar aliases to canonical comic extensions.
                    let canonicalExt: String
                    switch ext {
                    case "zip":     canonicalExt = "cbz"
                    case "rar":     canonicalExt = "cbr"
                    case "7z":      canonicalExt = "cb7"
                    default:        canonicalExt = ext
                    }

                    guard supportedExtensions.contains(canonicalExt) else { continue }

                    // Ensure the file is completely written before moving.
                    guard await isFileSettled(at: fileURL) else {
                        Logger.shared.log(
                            "SharedImportCoordinator: Skipping unsettled file: \(fileURL.lastPathComponent)",
                            category: "Import", type: .warning
                        )
                        continue
                    }

                    let base = (fileURL.deletingPathExtension().lastPathComponent)
                    let destFilename = "\(base).\(canonicalExt)"
                    let dest = inboxDir.appendingPathComponent(destFilename)

                    // Skip if an identical file is already in the inbox (dedup).
                    if fm.fileExists(atPath: dest.path) {
                        if (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64)
                            == (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) {
                            try? fm.removeItem(at: fileURL)
                            ingestedFilenames.append(destFilename)
                            Logger.shared.log(
                                "SharedImportCoordinator: Duplicate recognized & linked: \(destFilename)",
                                category: "Import"
                            )
                            continue
                        }
                        try? fm.removeItem(at: dest)
                    }

                    do {
                        try fm.moveItem(at: fileURL, to: dest)
                        ingestedFilenames.append(destFilename)
                        Logger.shared.log(
                            "SharedImportCoordinator: Moved '\(destFilename)' to InksyncVault/Inbox",
                            category: "Import", type: .success
                        )
                    } catch {
                        // Move failed (cross-device) — fall back to copy-then-delete.
                        if let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) {
                            do {
                                try data.write(to: dest, options: .atomic)
                                try? fm.removeItem(at: fileURL)
                                ingestedFilenames.append(destFilename)
                                Logger.shared.log(
                                    "SharedImportCoordinator: Streamed '\(destFilename)' to InksyncVault/Inbox",
                                    category: "Import", type: .success
                                )
                            } catch {
                                Logger.shared.log(
                                    "SharedImportCoordinator: Failed to ingest '\(fileURL.lastPathComponent)': \(error)",
                                    category: "Import", type: .error
                                )
                            }
                        }
                    }
                }
            }
        }
        return ingestedFilenames
    }

    // MARK: - Private: File Settle Check

    /// Returns true only when the file size is non-zero AND has not changed in the
    /// last 150ms — meaning the extension process has finished writing it.
    nonisolated private func isFileSettled(at url: URL) async -> Bool {
        let fm = FileManager.default
        guard let attrs1 = try? fm.attributesOfItem(atPath: url.path),
              let size1 = attrs1[.size] as? Int64, size1 > 0
        else { return false }

        // For very small files (<1MB) we trust immediately.
        if size1 < 1_048_576 { return true }

        // For larger files: compare size after 150ms async non-blocking sleep.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let attrs2 = try? fm.attributesOfItem(atPath: url.path),
              let size2 = attrs2[.size] as? Int64
        else { return false }
        return size1 == size2
    }

    // MARK: - Private: Clear App Group Flags

    nonisolated private func clearPendingShareFlags() {
        for groupID in appGroupIDs {
            if let ud = UserDefaults(suiteName: groupID) {
                ud.removeObject(forKey: "pendingShareImportTimestamp")
                ud.removeObject(forKey: "hasPendingShareImport")
                ud.synchronize()
            }
        }
    }

    // MARK: - Public: Consume after auto-select

    @discardableResult
    func consumeAutoSelectFilenames() -> Set<String> {
        let names = pendingAutoSelectFilenames
        pendingAutoSelectFilenames = []
        return names
    }

    // MARK: - Public: Has pending share from App Group

    func hasPendingShareImport() -> Bool {
        return appGroupIDs.contains(where: {
            (UserDefaults(suiteName: $0)?.double(forKey: "pendingShareImportTimestamp") ?? 0) > 0
        })
    }
}
