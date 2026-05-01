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
// ============================================================================

@MainActor
final class LinkedLibraryScanner: ObservableObject {

    static let shared = LinkedLibraryScanner()

    /// Published live during linkDrive scanning so the UI can display progress.
    @Published private(set) var scanStatus: String = ""

    private init() {
        // Observe stale bookmark notifications from BookmarkResolver
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
    func linkDrive(folderURL: URL, displayName: String? = nil) async throws -> AppSettingsManager.LinkedDriveEntry {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }

        scanStatus = "Creating bookmark…"

        // Create persistent bookmark. `.withSecurityScope` is required for cloud providers
        // (Dropbox, iCloud, Google Drive) so the bookmark survives app restarts.
        let bookmarkData: Data
        do {
            bookmarkData = try folderURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Fallback: no options (works for most local/USB volumes)
            bookmarkData = try folderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        // Probe write capability
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
        var entry = AppSettingsManager.LinkedDriveEntry(
            displayName: displayName ?? folderURL.lastPathComponent,
            volumeBookmarkData: bookmarkData,
            lastSeenDate: Date(),
            lastSyncedDate: Date(),
            fileCount: files.count,
            isReadOnly: isReadOnly
        )

        // Register all found files as linked ConvertedPDF entries
        await registerFiles(files, driveEntry: entry, rootURL: folderURL)

        // Save drive entry
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
        guard let url = try? await BookmarkResolver.shared.resolve(entry.volumeBookmarkData) else {
            Logger.shared.log("LinkedLibraryScanner: Could not resolve bookmark for '\(entry.displayName)'", category: "Drive", type: .warning)
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let foundFiles = scanDirectory(url)
        let foundPaths = Set(foundFiles.map { $0.path })

        guard let manager = conversionManager else { return }

        // Mark files that are no longer present on the drive
        for idx in manager.convertedPDFs.indices {
            if case .linked(let bm) = manager.convertedPDFs[idx].sourceMode,
               let resolved = try? await BookmarkResolver.shared.resolve(bm),
               !foundPaths.contains(resolved.path) {
                manager.convertedPDFs[idx].metadata.autoMatchFailed = true  // Reuse as "missing" flag
                Logger.shared.log("LinkedLibraryScanner: '\(manager.convertedPDFs[idx].name)' no longer found on drive", category: "Drive", type: .warning)
            }
        }

        // Add newly appeared files.
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

        // Update last seen date, file count, and sync timestamp
        var updated = entry
        updated.lastSeenDate = Date()
        updated.lastSyncedDate = Date()
        updated.fileCount = foundFiles.count
        AppSettingsManager.shared.updateLinkedDrive(updated)
        
        Task { await ThumbnailDaemon.shared.startCrawling(pdfs: manager.convertedPDFs) }
    }

    // MARK: - Re-link Drive (update bookmark, preserve library records)

    /// Called when a drive shows as disconnected but the user wants to re-establish the bookmark
    /// without wiping all the file records that were already registered.
    func relinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry, newFolderURL: URL) async throws {
        let accessing = newFolderURL.startAccessingSecurityScopedResource()
        defer { if accessing { newFolderURL.stopAccessingSecurityScopedResource() } }

        // Create a fresh bookmark for the re-selected folder
        let newBookmark: Data
        do {
            newBookmark = try newFolderURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            newBookmark = try newFolderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        // Update the drive entry's bookmark in-place
        var updated = entry
        updated.volumeBookmarkData = newBookmark
        updated.lastSeenDate = Date()
        updated.displayName = newFolderURL.lastPathComponent  // update in case path changed
        AppSettingsManager.shared.updateLinkedDrive(updated)

        // Run a sync to pick up any new files
        await syncDrive(updated)

        Logger.shared.log("LinkedLibraryScanner: Re-linked drive '\(updated.displayName)'", category: "Drive")
    }

    // MARK: - Unlink Drive

    /// Removes all linked entries for this drive from the library.
    func unlinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry) {
        guard let manager = conversionManager else { return }

        let rootPath: String?
        if let rootURL = try? BookmarkResolver.shared.resolve(entry.volumeBookmarkData) {
            rootPath = rootURL.path
        } else {
            rootPath = nil  // Bookmark unresolvable — fall back to bookmark-data match below
        }

        manager.convertedPDFs.removeAll { pdf in
            guard case .linked(let bm) = pdf.sourceMode else { return false }
            if let rp = rootPath {
                // Primary: path prefix match (reliable when drive is connected)
                if let resolved = try? BookmarkResolver.shared.resolve(bm) {
                    return resolved.path.hasPrefix(rp)
                }
                // Fallback: if individual bookmark is stale/unresolvable, match by drive bookmark equality
                return bm == entry.volumeBookmarkData
            } else {
                // Drive not connected — match by drive bookmark equality
                return bm == entry.volumeBookmarkData
            }
        }

        AppSettingsManager.shared.removeLinkedDrive(entry)
        manager.saveLibrary()
        Logger.shared.log("LinkedLibraryScanner: Unlinked drive '\(entry.displayName)'", category: "Drive")
    }

    // MARK: - Save File to Drive (Copy, No Delete)

    /// Copy one or more files into a user-chosen folder on the external drive.
    /// Unlike offloadToExternalDrive, the originals are NEVER deleted.
    /// Returns the number of files successfully saved.
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

            // Resolve source URL (linked files need bookmark resolution)
            let sourceURL: URL
            if case .linked(let bm) = pdf.sourceMode,
               let resolved = try? BookmarkResolver.shared.resolve(bm) {
                sourceURL = resolved
            } else {
                sourceURL = pdf.url
            }

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                Logger.shared.log("saveFilesToDrive: source not found for '\(pdf.name)' — skipping", category: "Drive", type: .warning)
                continue
            }

            // Build destination URL, deduplicating if a file already exists
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

    /// Copy local files to drive, verify, delete originals, flip sourceMode.
    func offloadToExternalDrive(
        files: [ConvertedPDF],
        targetFolderURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        // ⚠️ targetFolderURL is on an external drive — must acquire security-scoped access
        // before ANY file system operations underneath it.
        let accessing = targetFolderURL.startAccessingSecurityScopedResource()
        defer { if accessing { targetFolderURL.stopAccessingSecurityScopedResource() } }

        let total = files.count
        var copiedPairs: [(originalURL: URL, driveURL: URL, pdfID: UUID)] = []

        for (i, pdf) in files.enumerated() {
            progress(Double(i) / Double(total), "Copying \(pdf.name)...")

            let destURL = targetFolderURL.appendingPathComponent(pdf.url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: pdf.url, to: destURL)

                // Verify copy succeeded
                guard FileManager.default.fileExists(atPath: destURL.path) else {
                    Logger.shared.log("LinkedLibraryScanner: Copy verification failed for \(pdf.name) — skipping", category: "Drive", type: .warning)
                    continue
                }
                copiedPairs.append((pdf.url, destURL, pdf.id))
            } catch {
                // Clean up any partial copy so we don't orphan data on the drive
                try? FileManager.default.removeItem(at: destURL)
                Logger.shared.log("LinkedLibraryScanner: Offload copy failed for \(pdf.name): \(error.localizedDescription) — skipping", category: "Drive", type: .warning)
                // Continue with remaining files — partial success is better than total abort
            }
        }

        guard !copiedPairs.isEmpty else {
            throw NSError(domain: "LinkedLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey: "None of the selected files could be copied to the drive. Check available space and drive write permissions."])
        }

        progress(0.95, "Linking drive files...")

        // All copies verified — now delete originals and flip sourceMode
        guard let manager = conversionManager else { return }

        for pair in copiedPairs {
            // Create bookmark for new drive location
            guard let bookmark = try? pair.driveURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                Logger.shared.log("LinkedLibraryScanner: Could not bookmark drive file \(pair.driveURL.lastPathComponent) — keeping local copy", category: "Drive", type: .warning)
                try? FileManager.default.removeItem(at: pair.driveURL)  // Remove orphaned drive copy
                continue
            }

            // Update the ConvertedPDF entry in place (ID, metadata, collections preserved)
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pair.pdfID }) {
                manager.convertedPDFs[idx].url = pair.driveURL
                manager.convertedPDFs[idx].sourceMode = .linked(bookmarkData: bookmark)
            }

            // Delete original local file only after bookmark is secured
            try? FileManager.default.removeItem(at: pair.originalURL)
        }

        manager.saveLibrary()
        progress(1.0, "Offload complete — \(copiedPairs.count) of \(total) files moved")
        Logger.shared.log("LinkedLibraryScanner: Offloaded \(copiedPairs.count) files to drive", category: "Drive")
    }

    // MARK: - Download to Device (Drive → Local)

    /// Reverse offload: copy from drive back to local vault, flip sourceMode to .local.
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

                    // Remove existing file if present — prevents NSCocoaError.fileWriteFileExists crash
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

    private func scanDirectory(_ url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { file in
            supportedExtensions.contains(file.pathExtension.lowercased())
        }
    }

    private func registerFiles(
        _ files: [URL],
        driveEntry: AppSettingsManager.LinkedDriveEntry,
        rootURL: URL
    ) async {
        guard let manager = conversionManager else { return }

        // Build PDF entries serially (bookmark creation must be on the calling actor context)
        // but parallelize cover thumbnail extraction with a concurrency cap of 4.
        var newPDFs: [ConvertedPDF] = []

        for fileURL in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let fileSize = attrs[.size] as? Int64,
                  let bookmark = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            else { continue }

            // Skip if already registered (filename + linked status check)
            if manager.convertedPDFs.contains(where: { $0.url.lastPathComponent == fileURL.lastPathComponent && $0.isLinked }) {
                continue
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

        guard !newPDFs.isEmpty else { return }

        // Parallelize cover thumbnail extraction (capped at 4 concurrent tasks to avoid
        // thrashing the disk I/O bus on drives with slow random-access speeds).
        await withTaskGroup(of: (Int, Data?).self) { group in
            var inFlight = 0
            let cap = 4

            for (index, pdf) in newPDFs.enumerated() {
                // Throttle concurrency
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
            // Drain remaining
            for await (idx, data) in group {
                if let data { newPDFs[idx].coverImageData = data }
            }
        }

        manager.convertedPDFs.append(contentsOf: newPDFs)
        manager.saveLibrary()
    }

    private func generateAndCacheCover(for pdf: inout ConvertedPDF, at url: URL) async {
        // Extract first image from archive as a small cover thumbnail
        let coverImage = await Task.detached(priority: .background) {
            ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 300)
        }.value

        if let img = coverImage, let data = img.pngData() {
            pdf.coverImageData = data
        }
    }

    // MARK: - Stale Bookmark Refresh

    @objc private func handleStaleBookmark(_ notification: Notification) {
        guard let staleData = notification.object as? Data,
              let manager = conversionManager else { return }

        for idx in manager.convertedPDFs.indices {
            if case .linked(let bm) = manager.convertedPDFs[idx].sourceMode, bm == staleData {
                let name = manager.convertedPDFs[idx].name
                Logger.shared.log("LinkedLibraryScanner: Stale bookmark for '\(name)' — attempting refresh", category: "Drive", type: .warning)

                // Attempt to re-create a fresh bookmark from the stale URL.
                // resolve() returns a URL even when stale — it just flags isStale=true.
                // We can re-bookmark from that URL to get a fresh, durable bookmark.
                if let staleURL = try? BookmarkResolver.shared.resolve(staleData),
                   let freshBookmark = try? staleURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
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
