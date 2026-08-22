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
    /// scenePhase changes, and the `inksyncpro://` deep-link handler. Safe to call
    /// multiple times — it debounces internally.
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
                if !ingestedNames.isEmpty {
                    Logger.shared.log(
                        "SharedImportCoordinator: Completed import of \(ingestedNames.count) file(s), notifying system",
                        category: "Import", type: .success
                    )
                    NotificationCenter.default.post(
                        name: NSNotification.Name("InksyncPro.ShareImportReceived"),
                        object: nil
                    )
                    NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
                }
            }
        }
    }

    /// Centralized, failsafe direct file:// ingestion method.
    /// Handles security-scoped access, coordination, destination placement in InksyncVault/Inbox,
    /// and dispatches notifications for UI update.
    @discardableResult
    func handleDirectFileOpen(url: URL) async -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let filename = url.lastPathComponent
        let dest = inboxDir.appendingPathComponent(filename)

        // If file is already at destination and valid, register and return
        if dest.path == url.path && FileManager.default.fileExists(atPath: dest.path) {
            registerDirectlyOpenedFile(at: dest)
            NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
            return dest
        }

        try? FileManager.default.removeItem(at: dest)

        var copySuccess = false

        // Coordinate read via NSFileCoordinator
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: .withoutChanges, error: nil
        ) { safeURL in
            do {
                try FileManager.default.copyItem(at: safeURL, to: dest)
                copySuccess = true
            } catch {
                if let data = try? Data(contentsOf: safeURL, options: .alwaysMapped) {
                    copySuccess = (try? data.write(to: dest, options: .atomic)) != nil
                }
            }
        }

        // Direct stream fallback
        if !copySuccess, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            copySuccess = (try? data.write(to: dest, options: .atomic)) != nil
        }

        guard copySuccess else {
            Logger.shared.log(
                "SharedImportCoordinator: Failed to copy file \(filename) to InksyncVault/Inbox",
                category: "Import", type: .error
            )
            return nil
        }

        Logger.shared.log(
            "SharedImportCoordinator: Successfully ingested direct file '\(filename)' → InksyncVault/Inbox",
            category: "Import", type: .success
        )

        registerDirectlyOpenedFile(at: dest)
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncPro.DirectFileOpenReceived"),
            object: dest
        )
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
        return dest
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

    func hasPendingShareImport() -> Bool {
        if appGroupIDs.contains(where: {
            (UserDefaults(suiteName: $0)?.double(forKey: "pendingShareImportTimestamp") ?? 0) > 0 ||
            UserDefaults(suiteName: $0)?.bool(forKey: "hasPendingShareImport") == true
        }) {
            return true
        }

        // Also check physical directories in App Groups for any staged files
        let fm = FileManager.default
        for groupID in appGroupIDs {
            guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { continue }
            let stagingDirs = [
                container.appendingPathComponent("ShareStaging"),
                container.appendingPathComponent("Inbox"),
                container.appendingPathComponent("PendingConversions")
            ]
            for dir in stagingDirs {
                if let contents = try? fm.contentsOfDirectory(atPath: dir.path), !contents.isEmpty {
                    let validFiles = contents.filter { !$0.hasSuffix(".manifest.json") && !$0.hasPrefix(".") }
                    if !validFiles.isEmpty {
                        return true
                    }
                }
            }
        }
        return false
    }
}
