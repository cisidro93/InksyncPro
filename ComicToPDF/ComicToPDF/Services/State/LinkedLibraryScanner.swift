import Foundation
import UIKit

// ============================================================================
// LinkedLibraryScanner
// ============================================================================
// Manages the full lifecycle of external drive linking:
//  - Link a drive folder (register without copying)
//  - Sync on reconnect (non-destructive, preserves all metadata)
//  - Unlink a drive (clean removal)
//  - Offload to Drive (copy local → drive, flip sourceMode, free device storage)
//  - Download to Device (copy drive → local, flip sourceMode back)
//
// Bookmark Strategy (root cause of prior failures):
//  - All bookmarks MUST use .withSecurityScope so that resolved URLs can
//    call startAccessingSecurityScopedResource() AFTER the picker session ends.
//  - .minimalBookmark and [] options only work within the picker's active
//    security grant window — they silently break on every subsequent app launch.
//  - Per-file bookmarks are also security-scoped for the same reason.
// ============================================================================

@MainActor
final class LinkedLibraryScanner: ObservableObject {

    static let shared = LinkedLibraryScanner()

    /// Published live during linkDrive scanning so the UI can display progress.
    @Published private(set) var scanStatus: String = ""

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStaleBookmark(_:)),
            name: .bookmarkBecameStale,
            object: nil
        )
    }

    // Weak reference to the main library — injected at app startup
    weak var conversionManager: ConversionManager?

    // Supported comic/book file extensions
    private let supportedExtensions = ["cbz", "cbr", "cb7", "cbt", "epub", "pdf"]

    // MARK: - Link Drive

    /// Register a folder on an external drive or cloud provider. Files are never copied — only referenced.
    /// Uses .withSecurityScope bookmarks so that access survives app restarts and new sessions.
    func linkDrive(folderURL: URL, displayName: String? = nil) async throws -> AppSettingsManager.LinkedDriveEntry {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }

        scanStatus = "Creating bookmark…"

        // ✅ FIX #1: Always use .withSecurityScope for the drive root bookmark.
        // .minimalBookmark creates a non-scoped bookmark that becomes invalid the
        // moment the UIDocumentPickerViewController's implicit security grant expires.
        // .withSecurityScope is the ONLY option that survives app restarts on USB/cloud.
        let bookmarkData: Data
        do {
            bookmarkData = try folderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: [.isUbiquitousItemKey],
                relativeTo: nil
            )
        } catch {
            // Fallback for cloud providers (Dropbox, Google Drive) that don't support
            // security-scoped bookmarks directly — they manage their own access tokens.
            Logger.shared.log("LinkedLibraryScanner: .withSecurityScope bookmark failed, falling back for cloud provider: \(error.localizedDescription)", category: "Drive", type: .warning)
            bookmarkData = try folderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        // Probe write capability while access is still active
        let isReadOnly = !FileManager.default.isWritableFile(atPath: folderURL.path)

        // ━━ Move disk I/O off the MainActor ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        scanStatus = "Scanning folder…"
        let exts = supportedExtensions
        let files: [URL] = await Task.detached(priority: .userInitiated) {
            guard let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter {
                exts.contains($0.pathExtension.lowercased())
            }
        }.value

        scanStatus = "Found \(files.count) file\(files.count == 1 ? "" : "s") — registering…"
        Logger.shared.log("LinkedLibraryScanner: Scanned \(files.count) files in '\(folderURL.lastPathComponent)'", category: "Drive")

        // Build drive entry
        let entry = AppSettingsManager.LinkedDriveEntry(
            displayName: displayName ?? folderURL.lastPathComponent,
            volumeBookmarkData: bookmarkData,
            lastSeenDate: Date(),
            lastSyncedDate: Date(),
            fileCount: files.count,
            isReadOnly: isReadOnly
        )

        // Register all found files as linked ConvertedPDF entries
        // Pass folderURL so that per-file bookmarks are created while access is still live.
        await registerFiles(files, driveEntry: entry, rootURL: folderURL)

        AppSettingsManager.shared.addLinkedDrive(entry)
        Logger.shared.log("LinkedLibraryScanner: Linked drive '\(entry.displayName)' with \(files.count) files", category: "Drive")

        // Inform DriveMonitor of the updated drive list
        DriveMonitor.shared.startMonitoring(drives: AppSettingsManager.shared.linkedDrives)

        if let manager = conversionManager {
            Task { await ThumbnailDaemon.shared.startCrawling(pdfs: manager.convertedPDFs) }
        }

        scanStatus = ""
        return entry
    }

    // MARK: - Sync Drive

    /// Non-destructive re-scan when a drive reconnects. Preserves all metadata, progress, and collections.
    func syncDrive(_ entry: AppSettingsManager.LinkedDriveEntry) async {
        // ✅ FIX #2: Use the async BookmarkResolver.resolve() correctly with scoped access.
        // The nonisolated sync version silently succeeds with a URL that can't be opened.
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.volumeBookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            Logger.shared.log("LinkedLibraryScanner: Could not resolve bookmark for '\(entry.displayName)'", category: "Drive", type: .warning)
            return
        }

        if isStale {
            Logger.shared.log("LinkedLibraryScanner: Bookmark stale for '\(entry.displayName)' — requesting re-link", category: "Drive", type: .warning)
            NotificationCenter.default.post(name: .bookmarkBecameStale, object: entry.volumeBookmarkData)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.shared.log("LinkedLibraryScanner: Drive root not accessible for '\(entry.displayName)' — drive may have been disconnected", category: "Drive", type: .warning)
            return
        }

        let exts = supportedExtensions
        let foundFiles: [URL] = await Task.detached(priority: .userInitiated) { [exts] in
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter {
                exts.contains($0.pathExtension.lowercased())
            }
        }.value
        let foundPaths = Set(foundFiles.map { $0.path })

        guard let manager = conversionManager else { return }

        // Mark files that are no longer present on the drive
        for idx in manager.convertedPDFs.indices {
            if case .linked(let bm) = manager.convertedPDFs[idx].sourceMode {
                // ✅ FIX #3: Resolve per-file bookmark with .withSecurityScope so the
                // resolved URL can actually be probed. Without this the path check is meaningless.
                var fileIsStale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bm,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &fileIsStale
                ), !foundPaths.contains(resolved.path) {
                    manager.convertedPDFs[idx].metadata.autoMatchFailed = true
                    Logger.shared.log("LinkedLibraryScanner: '\(manager.convertedPDFs[idx].name)' no longer found on drive", category: "Drive", type: .warning)
                }
            }
        }

        // Add newly appeared files
        let existingFilenames = Set(manager.convertedPDFs.compactMap { pdf -> String? in
            guard case .linked = pdf.sourceMode else { return nil }
            return pdf.url.lastPathComponent
        })
        let newFiles = foundFiles.filter { !existingFilenames.contains($0.lastPathComponent) }
        if !newFiles.isEmpty {
            await registerFiles(newFiles, driveEntry: entry, rootURL: url)
            Logger.shared.log("LinkedLibraryScanner: Sync found \(newFiles.count) new files on '\(entry.displayName)'", category: "Drive")
            NotificationCenter.default.post(
                name: NSNotification.Name("LinkedLibraryNewFilesFound"),
                object: nil,
                userInfo: ["driveName": entry.displayName, "count": newFiles.count]
            )
        }

        var updated = entry
        updated.lastSeenDate = Date()
        updated.lastSyncedDate = Date()
        updated.fileCount = foundFiles.count
        AppSettingsManager.shared.updateLinkedDrive(updated)

        Task { await ThumbnailDaemon.shared.startCrawling(pdfs: manager.convertedPDFs) }
    }

    // MARK: - Re-link Drive (update bookmark, preserve library records)

    /// Called when a drive shows as disconnected. Re-establishes the security-scoped bookmark
    /// without wiping all the file records that were already registered.
    func relinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry, newFolderURL: URL) async throws {
        let accessing = newFolderURL.startAccessingSecurityScopedResource()
        defer { if accessing { newFolderURL.stopAccessingSecurityScopedResource() } }

        // ✅ FIX #4: Re-link also must produce a .withSecurityScope bookmark.
        let newBookmark: Data
        do {
            newBookmark = try newFolderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: [.isUbiquitousItemKey],
                relativeTo: nil
            )
        } catch {
            newBookmark = try newFolderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        var updated = entry
        updated.volumeBookmarkData = newBookmark
        updated.lastSeenDate = Date()
        updated.displayName = newFolderURL.lastPathComponent
        AppSettingsManager.shared.updateLinkedDrive(updated)

        // Re-sync to refresh per-file bookmarks for files that may have moved
        await syncDrive(updated)

        Logger.shared.log("LinkedLibraryScanner: Re-linked drive '\(updated.displayName)'", category: "Drive")
    }

    // MARK: - Unlink Drive

    /// Removes all linked entries for this drive from the library.
    /// Resolves bookmarks off the main thread to avoid USB I/O blocking.
    func unlinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry) {
        guard let manager = conversionManager else { return }

        // ✅ FIX #5: Resolve the root bookmark asynchronously off @MainActor to prevent
        // USB I/O from blocking the UI during unlink.
        Task.detached(priority: .userInitiated) { [weak manager] in
            // Attempt to resolve the root path. Failure is safe — fall back to bookmark equality.
            var rootPath: String? = nil
            if let rootURL = try? URL(
                resolvingBookmarkData: entry.volumeBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: nil
            ) {
                rootPath = rootURL.path
            }

            await MainActor.run {
                manager?.convertedPDFs.removeAll { pdf in
                    guard case .linked(let bm) = pdf.sourceMode else { return false }
                    if let rp = rootPath {
                        if let resolved = try? URL(
                            resolvingBookmarkData: bm,
                            options: .withSecurityScope,
                            relativeTo: nil,
                            bookmarkDataIsStale: nil
                        ) {
                            return resolved.path.hasPrefix(rp)
                        }
                        return bm == entry.volumeBookmarkData
                    } else {
                        return bm == entry.volumeBookmarkData
                    }
                }
                AppSettingsManager.shared.removeLinkedDrive(entry)
                manager?.saveLibrary()
                Logger.shared.log("LinkedLibraryScanner: Unlinked drive '\(entry.displayName)'", category: "Drive")
            }
        }
    }

    // MARK: - Save File to Drive (Copy, No Delete)

    func saveFilesToDrive(
        _ pdfs: [ConvertedPDF],
        targetFolderURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> Int {
        let accessing = targetFolderURL.startAccessingSecurityScopedResource()
        defer { if accessing { targetFolderURL.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.isWritableFile(atPath: targetFolderURL.path) else {
            throw NSError(domain: "LinkedLibrary", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The selected drive folder is read-only. Connect a writable drive or choose a different folder."])
        }

        let total = pdfs.count
        var savedCount = 0

        for (i, pdf) in pdfs.enumerated() {
            progress(Double(i) / Double(total), "Saving \(pdf.name)…")

            let sourceURL: URL
            if case .linked(let bm) = pdf.sourceMode,
               let resolved = try? URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: nil) {
                let didAccess = resolved.startAccessingSecurityScopedResource()
                defer { if didAccess { resolved.stopAccessingSecurityScopedResource() } }
                sourceURL = resolved
            } else {
                sourceURL = pdf.url
            }

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                Logger.shared.log("saveFilesToDrive: source not found for '\(pdf.name)' — skipping", category: "Drive", type: .warning)
                continue
            }

            var destURL = targetFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destURL.path) {
                let stem = destURL.deletingPathExtension().lastPathComponent
                let ext  = destURL.pathExtension
                var counter = 2
                repeat {
                    destURL = targetFolderURL.appendingPathComponent("\(stem) (\(counter)).\(ext)")
                    counter += 1
                } while FileManager.default.fileExists(atPath: destURL.path)
            }

            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                savedCount += 1
                Logger.shared.log("saveFilesToDrive: '\(pdf.name)' → '\(destURL.path)'", category: "Drive")
            } catch {
                Logger.shared.log("saveFilesToDrive: copy failed for '\(pdf.name)': \(error.localizedDescription)", category: "Drive", type: .warning)
            }
        }

        progress(1.0, "Saved \(savedCount) of \(total) files")
        return savedCount
    }

    // MARK: - Offload to Drive (Local → Drive)

    func offloadToExternalDrive(
        files: [ConvertedPDF],
        targetFolderURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let accessing = targetFolderURL.startAccessingSecurityScopedResource()
        defer { if accessing { targetFolderURL.stopAccessingSecurityScopedResource() } }

        let total = files.count
        var copiedPairs: [(originalURL: URL, driveURL: URL, pdfID: UUID)] = []

        for (i, pdf) in files.enumerated() {
            progress(Double(i) / Double(total), "Copying \(pdf.name)...")

            let destURL = targetFolderURL.appendingPathComponent(pdf.url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: pdf.url, to: destURL)

                guard FileManager.default.fileExists(atPath: destURL.path) else {
                    Logger.shared.log("LinkedLibraryScanner: Copy verification failed for \(pdf.name) — skipping", category: "Drive", type: .warning)
                    continue
                }
                copiedPairs.append((pdf.url, destURL, pdf.id))
            } catch {
                try? FileManager.default.removeItem(at: destURL)
                Logger.shared.log("LinkedLibraryScanner: Offload copy failed for \(pdf.name): \(error.localizedDescription) — skipping", category: "Drive", type: .warning)
            }
        }

        guard !copiedPairs.isEmpty else {
            throw NSError(domain: "LinkedLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey: "None of the selected files could be copied to the drive. Check available space and drive write permissions."])
        }

        progress(0.95, "Linking drive files...")

        guard let manager = conversionManager else { return }

        for pair in copiedPairs {
            // ✅ FIX #6: Per-file bookmark for offloaded files must also be .withSecurityScope.
            guard let bookmark = try? pair.driveURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else {
                Logger.shared.log("LinkedLibraryScanner: Could not bookmark drive file \(pair.driveURL.lastPathComponent) — keeping local copy", category: "Drive", type: .warning)
                try? FileManager.default.removeItem(at: pair.driveURL)
                continue
            }

            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pair.pdfID }) {
                manager.convertedPDFs[idx].url = pair.driveURL
                manager.convertedPDFs[idx].sourceMode = .linked(bookmarkData: bookmark)
            }

            try? FileManager.default.removeItem(at: pair.originalURL)
        }

        manager.saveLibrary()
        progress(1.0, "Offload complete — \(copiedPairs.count) of \(total) files moved")
        Logger.shared.log("LinkedLibraryScanner: Offloaded \(copiedPairs.count) files to drive", category: "Drive")
    }

    // MARK: - Download to Device (Drive → Local)

    func downloadToDevice(
        files: [ConvertedPDF],
        progress: @escaping (Double, String) -> Void
    ) async throws {
        guard let manager = conversionManager else { return }
        let vault = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("InksyncVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let total = files.count
        var downloadedCount = 0

        for (i, pdf) in files.enumerated() {
            progress(Double(i) / Double(total), "Downloading \(pdf.name)...")

            guard let bookmarkData = pdf.driveBookmarkData else { continue }

            do {
                try await BookmarkResolver.shared.withAccess(bookmarkData) { driveURL in
                    let destURL = vault.appendingPathComponent(driveURL.lastPathComponent)
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: driveURL, to: destURL)

                    await MainActor.run {
                        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                            manager.convertedPDFs[idx].url = destURL
                            manager.convertedPDFs[idx].sourceMode = .local
                        }
                    }
                }
                downloadedCount += 1
            } catch {
                Logger.shared.log("LinkedLibraryScanner: Download failed for \(pdf.name): \(error.localizedDescription) — skipping", category: "Drive", type: .warning)
            }
        }

        manager.saveLibrary()
        progress(1.0, "Download complete — \(downloadedCount) of \(total) files")
        Logger.shared.log("LinkedLibraryScanner: Downloaded \(downloadedCount) files to device", category: "Drive")
    }

    // MARK: - Private Helpers

    private func registerFiles(
        _ files: [URL],
        driveEntry: AppSettingsManager.LinkedDriveEntry,
        rootURL: URL
    ) async {
        guard let manager = conversionManager else { return }

        var newPDFs: [ConvertedPDF] = []

        for fileURL in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let fileSize = attrs[.size] as? Int64
            else { continue }

            // ✅ FIX #7: Per-file bookmarks MUST be .withSecurityScope.
            // Without this, the URL returned by resolve() cannot call
            // startAccessingSecurityScopedResource() and every file read fails silently.
            guard let bookmark = try? fileURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else {
                // Cloud providers (Dropbox, Google Drive) may not support per-file scoped
                // bookmarks. Fall back gracefully with an unscoped bookmark.
                guard let fallbackBookmark = try? fileURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) else { continue }

                Logger.shared.log("LinkedLibraryScanner: Fell back to unscoped bookmark for '\(fileURL.lastPathComponent)' — cloud provider detected", category: "Drive", type: .warning)
                await buildAndAppend(pdf: &newPDFs, fileURL: fileURL, fileSize: fileSize, bookmark: fallbackBookmark, manager: manager)
                continue
            }

            await buildAndAppend(pdf: &newPDFs, fileURL: fileURL, fileSize: fileSize, bookmark: bookmark, manager: manager)
        }

        guard !newPDFs.isEmpty else { return }

        // Parallelize cover thumbnail extraction (capped at 4 concurrent tasks)
        await withTaskGroup(of: (Int, Data?).self) { group in
            var inFlight = 0
            let cap = 4

            for (index, pdf) in newPDFs.enumerated() {
                if inFlight >= cap {
                    if let (idx, data) = await group.next() {
                        if let data { newPDFs[idx].coverImageData = data }
                        inFlight -= 1
                    }
                }
                let url = pdf.url
                group.addTask {
                    let img = await Task.detached(priority: .background) {
                        PhysicalFileSystemRouter.extractCoverImageStatic(from: url)
                    }.value
                    return (index, img?.pngData())
                }
                inFlight += 1
            }
            for await (idx, data) in group {
                if let data { newPDFs[idx].coverImageData = data }
            }
        }

        manager.convertedPDFs.append(contentsOf: newPDFs)
        manager.saveLibrary()
    }

    /// Builds a ConvertedPDF entry and appends it if not already registered.
    private func buildAndAppend(
        pdf newPDFs: inout [ConvertedPDF],
        fileURL: URL,
        fileSize: Int64,
        bookmark: Data,
        manager: ConversionManager
    ) async {
        // Skip if already registered (filename + linked status check)
        if manager.convertedPDFs.contains(where: { $0.url.lastPathComponent == fileURL.lastPathComponent && $0.isLinked }) {
            return
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        var metadata = PDFMetadata(title: stem)
        if let parsed = ComicInfoParser.parse(from: fileURL) {
            metadata.title = parsed.title ?? stem
            metadata.series = parsed.series ?? SeriesNameDetector.detect(from: fileURL.lastPathComponent).seriesName
            metadata.issueNumber = parsed.number
            metadata.volume = parsed.volume.map { String($0) }
            metadata.publisher = parsed.publisher
            metadata.summary = parsed.summary
            metadata.writer = parsed.writer
            metadata.isManga = parsed.manga ? true : nil
            metadata.tags = parsed.tags
        } else {
            metadata.series = SeriesNameDetector.detect(from: fileURL.lastPathComponent).seriesName
        }

        var pdf = ConvertedPDF(
            name: stem,
            url: fileURL,
            pageCount: 0,
            fileSize: fileSize,
            metadata: metadata
        )
        pdf.sourceMode = .linked(bookmarkData: bookmark)
        newPDFs.append(pdf)
    }

    @objc private func handleStaleBookmark(_ notification: Notification) {
        guard let staleData = notification.object as? Data,
              let manager = conversionManager else { return }

        for idx in manager.convertedPDFs.indices {
            if case .linked(let bm) = manager.convertedPDFs[idx].sourceMode, bm == staleData {
                let name = manager.convertedPDFs[idx].name
                Logger.shared.log("LinkedLibraryScanner: Stale bookmark for '\(name)' — attempting refresh", category: "Drive", type: .warning)

                // Re-resolve the stale bookmark to get a URL, then re-create a .withSecurityScope bookmark.
                var isStale = false
                if let staleURL = try? URL(
                    resolvingBookmarkData: staleData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ), let freshBookmark = try? staleURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    manager.convertedPDFs[idx].sourceMode = .linked(bookmarkData: freshBookmark)
                    Logger.shared.log("LinkedLibraryScanner: Refreshed bookmark for '\(name)'", category: "Drive")
                } else {
                    Logger.shared.log("LinkedLibraryScanner: Could not refresh bookmark for '\(name)' — drive may be disconnected", category: "Drive", type: .error)
                }
            }
        }

        manager.saveLibrary()
    }
}
