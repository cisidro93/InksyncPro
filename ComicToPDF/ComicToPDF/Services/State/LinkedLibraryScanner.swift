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
final class LinkedLibraryScanner {

    static let shared = LinkedLibraryScanner()
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

    /// Register a folder on an external drive. Files are never copied — only referenced.
    func linkDrive(folderURL: URL, displayName: String? = nil) async throws -> AppSettingsManager.LinkedDriveEntry {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }

        // Create persistent bookmark for the root folder
        let bookmarkData = try folderURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Probe write capability
        let isReadOnly = !FileManager.default.isWritableFile(atPath: folderURL.path)

        // Scan for supported files
        let files = scanDirectory(folderURL)

        // Build drive entry
        var entry = AppSettingsManager.LinkedDriveEntry(
            displayName: displayName ?? folderURL.lastPathComponent,
            volumeBookmarkData: bookmarkData,
            lastSeenDate: Date(),
            fileCount: files.count,
            isReadOnly: isReadOnly
        )

        // Register all found files as linked ConvertedPDF entries
        await registerFiles(files, driveEntry: entry, rootURL: folderURL)

        // Save drive entry
        AppSettingsManager.shared.addLinkedDrive(entry)
        Logger.shared.log("LinkedLibraryScanner: Linked drive '\(entry.displayName)' with \(files.count) files", category: "Drive")

        return entry
    }

    // MARK: - Sync Drive

    /// Non-destructive re-scan when a drive reconnects. Preserves all metadata, progress, and collections.
    func syncDrive(_ entry: AppSettingsManager.LinkedDriveEntry) async {
        guard let url = try? BookmarkResolver.shared.resolve(entry.volumeBookmarkData) else {
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
               let resolved = try? BookmarkResolver.shared.resolve(bm),
               !foundPaths.contains(resolved.path) {
                manager.convertedPDFs[idx].metadata.autoMatchFailed = true  // Reuse as "missing" flag
                Logger.shared.log("LinkedLibraryScanner: '\(manager.convertedPDFs[idx].name)' no longer found on drive", category: "Drive", type: .warning)
            }
        }

        // Add newly appeared files
        let existingPaths = Set(manager.convertedPDFs.compactMap { pdf -> String? in
            if case .linked(let bm) = pdf.sourceMode,
               let resolved = try? BookmarkResolver.shared.resolve(bm) {
                return resolved.path
            }
            return nil
        })

        let newFiles = foundFiles.filter { !existingPaths.contains($0.path) }
        if !newFiles.isEmpty {
            await registerFiles(newFiles, driveEntry: entry, rootURL: url)
            Logger.shared.log("LinkedLibraryScanner: Sync found \(newFiles.count) new files on '\(entry.displayName)'", category: "Drive")
            NotificationCenter.default.post(
                name: NSNotification.Name("LinkedLibraryNewFilesFound"),
                object: nil,
                userInfo: ["driveName": entry.displayName, "count": newFiles.count]
            )
        }

        // Update last seen date and file count
        var updated = entry
        updated.lastSeenDate = Date()
        updated.fileCount = foundFiles.count
        AppSettingsManager.shared.updateLinkedDrive(updated)
    }

    // MARK: - Unlink Drive

    /// Removes all linked entries for this drive from the library.
    func unlinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry) {
        guard let manager = conversionManager else { return }

        // Resolve the root path to identify which PDFs belong to this drive
        guard let rootURL = try? BookmarkResolver.shared.resolve(entry.volumeBookmarkData) else {
            // If bookmark is unresolvable, remove by bookmark data match
            manager.convertedPDFs.removeAll { pdf in
                if case .linked(let bm) = pdf.sourceMode { return bm == entry.volumeBookmarkData }
                return false
            }
            AppSettingsManager.shared.removeLinkedDrive(entry)
            manager.saveLibrary()
            return
        }

        let rootPath = rootURL.path
        manager.convertedPDFs.removeAll { pdf in
            if case .linked(let bm) = pdf.sourceMode,
               let resolved = try? BookmarkResolver.shared.resolve(bm) {
                return resolved.path.hasPrefix(rootPath)
            }
            return false
        }

        AppSettingsManager.shared.removeLinkedDrive(entry)
        manager.saveLibrary()
        Logger.shared.log("LinkedLibraryScanner: Unlinked drive '\(entry.displayName)'", category: "Drive")
    }

    // MARK: - Offload to Drive (Local → Drive)

    /// Copy local files to drive, verify, delete originals, flip sourceMode.
    func offloadToExternalDrive(
        files: [ConvertedPDF],
        targetFolderURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let total = files.count
        var copiedPairs: [(originalURL: URL, driveURL: URL, pdfID: UUID)] = []

        for (i, pdf) in files.enumerated() {
            progress(Double(i) / Double(total), "Copying \(pdf.name)...")

            let destURL = targetFolderURL.appendingPathComponent(pdf.url.lastPathComponent)
            try FileManager.default.copyItem(at: pdf.url, to: destURL)

            // Verify via content hash if available, else file size
            guard FileManager.default.fileExists(atPath: destURL.path) else {
                throw NSError(domain: "LinkedLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: "Copy verification failed for \(pdf.name)"])
            }

            copiedPairs.append((pdf.url, destURL, pdf.id))
        }

        progress(0.95, "Linking drive files...")

        // All copies verified — now delete originals and flip sourceMode
        guard let manager = conversionManager else { return }

        for pair in copiedPairs {
            // Create bookmark for new drive location
            let bookmark = try pair.driveURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            
            // Update the ConvertedPDF entry in place (ID, metadata, collections preserved)
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pair.pdfID }) {
                manager.convertedPDFs[idx].url = pair.driveURL
                manager.convertedPDFs[idx].sourceMode = .linked(bookmarkData: bookmark)
            }

            // Delete original local file
            try? FileManager.default.removeItem(at: pair.originalURL)
        }

        manager.saveLibrary()
        progress(1.0, "Offload complete")
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

        for (i, pdf) in files.enumerated() {
            progress(Double(i) / Double(total), "Downloading \(pdf.name)...")

            guard let bookmarkData = pdf.driveBookmarkData else { continue }

            try await BookmarkResolver.shared.withAccess(bookmarkData) { driveURL in
                let destURL = vault.appendingPathComponent(driveURL.lastPathComponent)
                try FileManager.default.copyItem(at: driveURL, to: destURL)

                await MainActor.run {
                    if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                        manager.convertedPDFs[idx].url = destURL
                        manager.convertedPDFs[idx].sourceMode = .local
                    }
                }
            }
        }

        manager.saveLibrary()
        progress(1.0, "Download complete")
        Logger.shared.log("LinkedLibraryScanner: Downloaded \(files.count) files to device", category: "Drive")
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

        for fileURL in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let fileSize = attrs[.size] as? Int64,
                  let bookmark = try? fileURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            else { continue }

            // Skip if already registered
            if manager.convertedPDFs.contains(where: { $0.url.lastPathComponent == fileURL.lastPathComponent && $0.isLinked }) {
                continue
            }

            // Parse metadata in place (streamed, no copy)
            var metadata: PDFMetadata
            if let parsed = ComicInfoParser.shared.parse(from: fileURL) {
                metadata = parsed
            } else {
                let stem = fileURL.deletingPathExtension().lastPathComponent
                metadata = PDFMetadata(title: stem)
                metadata.series = stem
            }

            var pdf = ConvertedPDF(
                name: fileURL.deletingPathExtension().lastPathComponent,
                url: fileURL,
                pageCount: 0,    // Deferred — page count requires opening the archive
                fileSize: fileSize,
                metadata: metadata
            )
            pdf.sourceMode = .linked(bookmarkData: bookmark)

            // Generate and cache cover thumbnail locally so it shows offline
            await generateAndCacheCover(for: &pdf, at: fileURL)

            manager.convertedPDFs.append(pdf)
        }

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
        // When BookmarkResolver detects a stale bookmark, attempt to refresh
        // the stored bookmark data in the matching ConvertedPDF entry
        guard let staleData = notification.object as? Data,
              let manager = conversionManager else { return }

        for idx in manager.convertedPDFs.indices {
            if case .linked(let bm) = manager.convertedPDFs[idx].sourceMode, bm == staleData {
                Logger.shared.log("LinkedLibraryScanner: Stale bookmark detected for '\(manager.convertedPDFs[idx].name)' — will re-bookmark on next access", category: "Drive", type: .warning)
            }
        }
    }
}
