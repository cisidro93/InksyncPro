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
// iOS Bookmark Strategy:
//  - .withSecurityScope is macOS-only and UNAVAILABLE on iOS.
//  - On iOS, bookmark creation uses options: [] — the document picker's security
//    grant is inherited automatically when the URL was provided by the picker.
//  - Resolution uses options: .withoutUI to suppress blocking system dialogs.
//  - startAccessingSecurityScopedResource() must still be called on the resolved
//    URL to activate the grant for file I/O beyond the picker session.
// ============================================================================

enum LinkedLibraryError: LocalizedError, Sendable {
    case bookmarkResolutionFailed
    case folderNotAccessible
    case readOnlyFolder
    case copyFailed
    
    var errorDescription: String? {
        switch self {
        case .bookmarkResolutionFailed:
            return "Could not secure access to this folder. Please try linking it again."
        case .folderNotAccessible:
            return "The selected folder is not accessible or access was revoked."
        case .readOnlyFolder:
            return "The selected drive folder is read-only."
        case .copyFailed:
            return "None of the selected files could be copied to the drive."
        }
    }
}

@MainActor
final class LinkedLibraryScanner: ObservableObject {

    static let shared = LinkedLibraryScanner()

    private var activeSyncDrives = Set<UUID>()

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
    private let supportedExtensions = ["pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip", "rar"]

    /// Drives with more files than this threshold are treated as "large drives".
    /// Large drives are registered as a single DriveFolder card in the library
    /// rather than dumping every file flat into convertedPDFs, which would freeze
    /// SwiftUI diffing and produce multi-second JSON serializations.
    nonisolated static let largeDriveThreshold = 500

    // MARK: - Link Drive

    /// Register a folder on an external drive or cloud provider.
    /// Files are never copied — only referenced via persistent bookmarks.
    func linkDrive(folderURL: URL, bookmarkData: Data, displayName: String? = nil) async throws -> AppSettingsManager.LinkedDriveEntry {
        defer {
            scanStatus = ""
        }

        let resolvedURL: URL
        if let resolved = try? BookmarkResolver.shared.resolve(bookmarkData) {
            resolvedURL = resolved
        } else {
            resolvedURL = folderURL
        }

        let accessing = resolvedURL.startAccessingSecurityScopedResource()
        defer { if accessing { resolvedURL.stopAccessingSecurityScopedResource() } }

        // Probe write capability while access is active
        let isReadOnly = !FileManager.default.isWritableFile(atPath: resolvedURL.path)

        // Move disk I/O off the MainActor: safely scan folder with timeout and system directory guards
        scanStatus = "Scanning folder…"
        let exts = supportedExtensions
        let files: [URL] = await Task.detached(priority: .userInitiated) { [resolvedURL] in
            let accessingDetached = resolvedURL.startAccessingSecurityScopedResource()
            defer { if accessingDetached { resolvedURL.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let enumerator = fm.enumerator(
                at: resolvedURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var collected: [URL] = []
            var enumCount = 0
            let startTime = Date()

            while let fileURL = enumerator.nextObject() as? URL {
                enumCount += 1
                if enumCount % 25 == 0 {
                    await Task.yield()
                    // Cap folder spidering at 60 seconds or largeDriveThreshold files so external drives never hang
                    if Date().timeIntervalSince(startTime) > 60.0 || collected.count >= LinkedLibraryScanner.largeDriveThreshold {
                        break
                    }
                }

                let lastComp = fileURL.lastPathComponent
                if lastComp.hasPrefix(".") || lastComp == "System Volume Information" || lastComp == "$RECYCLE.BIN" || lastComp == ".Spotlight-V100" || lastComp == ".Trashes" {
                    enumerator.skipDescendants()
                    continue
                }

                guard let rsrc = try? fileURL.resourceValues(forKeys: Set(keys)),
                      rsrc.isDirectory == false else { continue }
                if exts.contains(fileURL.pathExtension.lowercased()) {
                    collected.append(fileURL)
                }
            }
            return collected
        }.value

        scanStatus = "Found \(files.count) file\(files.count == 1 ? "" : "s") — registering…"
        Logger.shared.log("LinkedLibraryScanner: Scanned \(files.count) files in '\(resolvedURL.lastPathComponent)'", category: "Drive")

        let entry = AppSettingsManager.LinkedDriveEntry(
            displayName: displayName ?? resolvedURL.lastPathComponent,
            volumeBookmarkData: bookmarkData,
            lastSeenDate: Date(),
            lastSyncedDate: Date(),
            fileCount: files.count,
            isReadOnly: isReadOnly
        )

        // Register files into convertedPDFs so they appear in the library with series buckets
        await registerFiles(files, driveEntry: entry, rootURL: resolvedURL)

        AppSettingsManager.shared.addLinkedDrive(entry)
        DriveMonitor.shared.markConnected(driveID: entry.id)
        DriveMonitor.shared.startMonitoring(drives: AppSettingsManager.shared.linkedDrives)
        Logger.shared.log("LinkedLibraryScanner: Linked drive '\(entry.displayName)' with \(files.count) files", category: "Drive")

        if let manager = conversionManager {
            if files.count > 0 && files.count <= 100 {
                Task { await ThumbnailDaemon.shared.startCrawling(pdfs: manager.convertedPDFs) }
            }
        }

        return entry
    }

    // MARK: - Link Individual Files

    /// Register individual comic or document files from external drives without copying.
    func linkFiles(pickedFiles: [(url: URL, bookmark: Data)]) async -> Int {
        defer {
            scanStatus = ""
        }
        let manager = conversionManager ?? ConversionManager.shared
        guard !pickedFiles.isEmpty else { return 0 }

        scanStatus = "Linking \(pickedFiles.count) file\(pickedFiles.count == 1 ? "" : "s")…"
        let existingPaths = Set(manager.convertedPDFs.filter { $0.isLinked }.map { $0.url.path })

        let newPDFs = await Task.detached(priority: .userInitiated) { () -> [ConvertedPDF] in
            var tempPDFs: [ConvertedPDF] = []
            for item in pickedFiles {
                var isStale = false
                let fileURL = (try? URL(
                    resolvingBookmarkData: item.bookmark,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )) ?? item.url

                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

                var bookmark = item.bookmark
                if let fresh = try? fileURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    bookmark = fresh
                }

                if existingPaths.contains(fileURL.path) { continue }

                let fileAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = (fileAttrs?[.size] as? Int64) ?? 0

                let stem = fileURL.deletingPathExtension().lastPathComponent
                let parsedTokens = DeterministicFilenameParser.parse(filename: fileURL.lastPathComponent)
                let parentFolder = fileURL.deletingLastPathComponent().lastPathComponent

                var metadata = PDFMetadata(title: parsedTokens.title ?? stem)
                if pickedFiles.count <= 15, let parsed = ComicInfoParser.parse(from: fileURL) {
                    metadata.title = parsed.title ?? stem
                    metadata.series = parsed.series ?? (parsedTokens.seriesName.isEmpty ? parentFolder : parsedTokens.seriesName)
                    metadata.issueNumber = parsed.number ?? parsedTokens.issueNumber
                    metadata.volume = parsed.volume.map { String($0) } ?? parsedTokens.volume
                    metadata.publisher = parsed.publisher
                    metadata.summary = parsed.summary
                    metadata.writer = parsed.writer
                    metadata.isManga = parsed.manga ? true : nil
                } else {
                    metadata.series = parsedTokens.seriesName.isEmpty ? parentFolder : parsedTokens.seriesName
                    metadata.volume = parsedTokens.volume
                    metadata.issueNumber = parsedTokens.issueNumber
                }

                var pdf = ConvertedPDF(
                    name: stem,
                    url: fileURL,
                    pageCount: 0,
                    fileSize: fileSize,
                    metadata: metadata
                )
                pdf.sourceMode = .linked(bookmarkData: bookmark)
                tempPDFs.append(pdf)
            }
            return tempPDFs
        }.value

        guard !newPDFs.isEmpty else {
            scanStatus = ""
            return 0
        }

        manager.convertedPDFs.append(contentsOf: newPDFs)
        manager.saveLibrary()

        // Sync with authoritative LibraryService
        var existingIDs = Set(LibraryService.shared.items.map(\.id))
        var authoritativePaths = Set(LibraryService.shared.items.map { $0.url.fastCanonicalPath })
        for pdf in newPDFs {
            let p = pdf.url.fastCanonicalPath
            if !existingIDs.contains(pdf.id) && !authoritativePaths.contains(p) {
                existingIDs.insert(pdf.id)
                authoritativePaths.insert(p)
                LibraryService.shared.items.append(pdf)
            }
        }
        LibraryService.shared.saveLibrary(isStructural: true)
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)

        // If files are from an external drive, ensure a linked drive entry exists so DriveMonitor monitors it
        if let firstItem = pickedFiles.first {
            let parentDir = firstItem.url.deletingLastPathComponent()
            let driveName = parentDir.lastPathComponent.isEmpty ? "External Drive" : parentDir.lastPathComponent
            if !AppSettingsManager.shared.linkedDrives.contains(where: { $0.displayName == driveName }) {
                let entry = AppSettingsManager.LinkedDriveEntry(
                    displayName: driveName,
                    volumeBookmarkData: firstItem.bookmark,
                    lastSeenDate: Date(),
                    lastSyncedDate: Date(),
                    fileCount: newPDFs.count,
                    isReadOnly: false
                )
                AppSettingsManager.shared.addLinkedDrive(entry)
                DriveMonitor.shared.startMonitoring(drives: AppSettingsManager.shared.linkedDrives)
            }
        }

        if newPDFs.count <= 100 {
            Task { await ThumbnailDaemon.shared.startCrawling(pdfs: manager.convertedPDFs) }
        }
        scanStatus = ""
        Logger.shared.log("LinkedLibraryScanner: Directly linked \(newPDFs.count) individual comic/book files", category: "Drive", type: .success)
        return newPDFs.count
    }

    // MARK: - Sync Drive

    /// Non-destructive re-scan when a drive reconnects.
    func syncDrive(_ entry: AppSettingsManager.LinkedDriveEntry) async {
        guard !activeSyncDrives.contains(entry.id) else {
            Logger.shared.log("LinkedLibraryScanner: Sync already in progress for '\(entry.displayName)' — skipping", category: "Drive", type: .info)
            return
        }
        activeSyncDrives.insert(entry.id)
        defer { activeSyncDrives.remove(entry.id) }

        // Move the volume root bookmark resolution to a background thread to prevent UI freezing
        let volumeData = entry.volumeBookmarkData
        let (resolvedURL, volumeIsStale) = await Task.detached(priority: .userInitiated) { () -> (URL?, Bool) in
            var isStale = false
            let url = try? URL(
                resolvingBookmarkData: volumeData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }.value

        guard let url = resolvedURL else {
            Logger.shared.log("LinkedLibraryScanner: Could not resolve bookmark for '\(entry.displayName)'", category: "Drive", type: .warning)
            return
        }

        if volumeIsStale {
            Logger.shared.log("LinkedLibraryScanner: Bookmark stale for '\(entry.displayName)' — requesting re-link", category: "Drive", type: .warning)
            NotificationCenter.default.post(name: .bookmarkBecameStale, object: entry.volumeBookmarkData)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.shared.log("LinkedLibraryScanner: Drive root not accessible for '\(entry.displayName)'", category: "Drive", type: .warning)
            return
        }

        let exts = supportedExtensions
        let foundFiles: [URL] = await Task.detached(priority: .userInitiated) { [exts, url] in
            let accessingDetached = url.startAccessingSecurityScopedResource()
            defer { if accessingDetached { url.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var collected: [URL] = []
            var enumCount = 0
            while let fileURL = enumerator.nextObject() as? URL {
                enumCount += 1
                if enumCount % 25 == 0 { await Task.yield() }

                guard let rsrc = try? fileURL.resourceValues(forKeys: Set(keys)),
                      rsrc.isDirectory == false else { continue }
                if exts.contains(fileURL.pathExtension.lowercased()) {
                    collected.append(fileURL)
                }
            }
            return collected
        }.value
        let foundPaths = Set(foundFiles.map { $0.path })

        guard let manager = conversionManager else { return }

        // Move individual book bookmark resolution to background task to avoid UI freezes
        let linkedItems = manager.convertedPDFs.compactMap { pdf -> (id: UUID, bookmark: Data)? in
            if case .linked(let bm) = pdf.sourceMode {
                return (pdf.id, bm)
            }
            return nil
        }

        let resolvedPathCache = await Task.detached(priority: .userInitiated) { () -> [UUID: String] in
            var cache: [UUID: String] = [:]
            for item in linkedItems {
                var fileIsStale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: item.bookmark,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &fileIsStale
                ) {
                    cache[item.id] = resolved.path
                }
            }
            return cache
        }.value

        // Mark files no longer present on the drive
        for idx in manager.convertedPDFs.indices {
            if case .linked = manager.convertedPDFs[idx].sourceMode {
                let pdfID = manager.convertedPDFs[idx].id
                if let resolvedPath = resolvedPathCache[pdfID], !foundPaths.contains(resolvedPath) {
                    manager.convertedPDFs[idx].metadata.autoMatchFailed = true
                    Logger.shared.log("LinkedLibraryScanner: '\(manager.convertedPDFs[idx].name)' no longer found on drive", category: "Drive", type: .warning)
                }
            }
        }

        // Add newly appeared files
        let existingPaths = Set(resolvedPathCache.values)
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

        var updated = entry
        updated.lastSeenDate = Date()
        updated.lastSyncedDate = Date()
        updated.fileCount = foundFiles.count
        AppSettingsManager.shared.updateLinkedDrive(updated)

        Task { await ThumbnailDaemon.shared.startCrawling(pdfs: manager.convertedPDFs) }
    }

    // MARK: - Re-link Drive

    /// Re-establishes the bookmark for a disconnected drive without wiping library records.
    func relinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry, newFolderURL: URL, newBookmarkData: Data) async throws {
        var updated = entry
        updated.volumeBookmarkData = newBookmarkData
        updated.lastSeenDate = Date()
        updated.displayName = newFolderURL.lastPathComponent
        AppSettingsManager.shared.updateLinkedDrive(updated)

        await syncDrive(updated)

        Logger.shared.log("LinkedLibraryScanner: Re-linked drive '\(updated.displayName)'", category: "Drive")
    }

    // MARK: - Unlink Drive

    /// Removes all linked entries for this drive from the library.
    func unlinkDrive(_ entry: AppSettingsManager.LinkedDriveEntry) {
        guard let manager = conversionManager else { return }

        let volumeData = entry.volumeBookmarkData
        let linkedPDFsData = manager.convertedPDFs.compactMap { pdf -> (UUID, Data)? in
            guard case .linked(let bm) = pdf.sourceMode else { return nil }
            return (pdf.id, bm)
        }

        Task {
            let idsToRemove = await Task.detached(priority: .userInitiated) { () -> Set<UUID> in
                var toRemove = Set<UUID>()
                var isStale = false
                var rootPath: String? = nil
                if let rootURL = try? URL(
                    resolvingBookmarkData: volumeData,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    rootPath = rootURL.path
                }

                for (id, bm) in linkedPDFsData {
                    if let rp = rootPath {
                        var fileIsStale = false
                        if let resolved = try? URL(
                            resolvingBookmarkData: bm,
                            options: .withoutUI,
                            relativeTo: nil,
                            bookmarkDataIsStale: &fileIsStale
                        ) {
                            if resolved.path.hasPrefix(rp) {
                                toRemove.insert(id)
                                continue
                            }
                        }
                    }
                    if bm == volumeData {
                        toRemove.insert(id)
                    }
                }
                return toRemove
            }.value

            manager.convertedPDFs.removeAll { idsToRemove.contains($0.id) }
            AppSettingsManager.shared.removeLinkedDrive(entry)
            manager.saveLibrary()
            Logger.shared.log("LinkedLibraryScanner: Unlinked drive '\(entry.displayName)'", category: "Drive")
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
                          userInfo: [NSLocalizedDescriptionKey: "The selected drive folder is read-only."])
        }

        let total = pdfs.count
        var savedCount = 0

        for (i, pdf) in pdfs.enumerated() {
            progress(Double(i) / Double(total), "Saving \(pdf.name)…")

            let sourceURL: URL
            if case .linked(let bm) = pdf.sourceMode,
               let resolved = try? BookmarkResolver.shared.resolve(bm) {
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
                try AtomicFileCoordinator.importFile(from: sourceURL, to: destURL, useMoveIfStaged: false)
                savedCount += 1
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

        guard FileManager.default.isWritableFile(atPath: targetFolderURL.path) else {
            throw LinkedLibraryError.readOnlyFolder
        }

        let total = files.count
        var copiedPairs: [(originalURL: URL, driveURL: URL, pdfID: UUID)] = []

        for (i, pdf) in files.enumerated() {
            progress(Double(i) / Double(total), "Copying \(pdf.name)...")

            let destURL = targetFolderURL.appendingPathComponent(pdf.url.lastPathComponent)
            do {
                try AtomicFileCoordinator.importFile(from: pdf.url, to: destURL, useMoveIfStaged: false)
                copiedPairs.append((pdf.url, destURL, pdf.id))
            } catch {
                Logger.shared.log("LinkedLibraryScanner: Offload copy failed for \(pdf.name): \(error.localizedDescription)", category: "Drive", type: .warning)
            }
        }

        guard !copiedPairs.isEmpty else {
            throw LinkedLibraryError.copyFailed
        }

        progress(0.95, "Linking drive files...")
        guard let manager = conversionManager else { return }

        let folderBookmark = try? targetFolderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let folderBookmark {
            BookmarkResolver.registerDriveBookmark(folderBookmark)
        }

        for pair in copiedPairs {
            let perFileBookmark = try? pair.driveURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let chosenBookmark = folderBookmark ?? perFileBookmark
            guard let bookmark = chosenBookmark else {
                Logger.shared.log("LinkedLibraryScanner: Could not bookmark \(pair.driveURL.lastPathComponent) — keeping local copy", category: "Drive", type: .warning)
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
        let vault = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
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
                    try AtomicFileCoordinator.importFile(from: driveURL, to: destURL, useMoveIfStaged: false)
                    PhysicalFileSystemRouter.excludeFromBackup(at: destURL)

                    await MainActor.run {
                        if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                            manager.convertedPDFs[idx].url = destURL
                            manager.convertedPDFs[idx].sourceMode = .local
                        }
                    }
                }
                downloadedCount += 1
            } catch {
                Logger.shared.log("LinkedLibraryScanner: Download failed for \(pdf.name): \(error.localizedDescription)", category: "Drive", type: .warning)
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
        defer {
            scanStatus = ""
        }
        guard let manager = conversionManager else { return }

        // Fetch existing paths on MainActor to avoid data races
        let existingPaths = Set(manager.convertedPDFs.filter { $0.isLinked }.map { $0.url.path })

        let chunkSize = 50
        let total = files.count
        var allNewPDFs: [ConvertedPDF] = []
        allNewPDFs.reserveCapacity(min(total, 500))

        for chunkStart in stride(from: 0, to: total, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, total)
            let chunkFiles = Array(files[chunkStart..<chunkEnd])

            scanStatus = "Cataloging \(chunkStart) of \(total) files…"

            let chunkPDFs = await Task.detached(priority: .userInitiated) { [rootURL, driveBookmark = driveEntry.volumeBookmarkData] () -> [ConvertedPDF] in
                let accessing = rootURL.startAccessingSecurityScopedResource()
                defer { if accessing { rootURL.stopAccessingSecurityScopedResource() } }

                var tempPDFs: [ConvertedPDF] = []
                tempPDFs.reserveCapacity(chunkFiles.count)

                for fileURL in chunkFiles {
                    if existingPaths.contains(fileURL.path) { continue }

                    let fileAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let fileSize = (fileAttrs?[.size] as? Int64) ?? 0

                    let stem = fileURL.deletingPathExtension().lastPathComponent
                    let parsedTokens = DeterministicFilenameParser.parse(filename: fileURL.lastPathComponent)

                    let parentFolderName = fileURL.deletingLastPathComponent().lastPathComponent
                    let fallbackSeriesName = (parentFolderName != rootURL.lastPathComponent && !parentFolderName.isEmpty)
                        ? parentFolderName
                        : SeriesNameDetector.detect(from: fileURL.lastPathComponent).seriesName

                    var metadata = PDFMetadata(title: parsedTokens.title ?? stem)
                    // For small batches (<= 15 items), attempt rich ComicInfo parse if fast
                    if total <= 15, let parsed = ComicInfoParser.parse(from: fileURL) {
                        metadata.title = parsed.title ?? stem
                        let candidateSeries = parsed.series ?? (parsedTokens.seriesName.isEmpty ? fallbackSeriesName : parsedTokens.seriesName)
                        metadata.series = candidateSeries.isEmpty ? fallbackSeriesName : candidateSeries
                        metadata.issueNumber = parsed.number ?? parsedTokens.issueNumber
                        metadata.volume = parsed.volume.map { String($0) } ?? parsedTokens.volume
                        metadata.publisher = parsed.publisher
                        metadata.summary = parsed.summary
                        metadata.writer = parsed.writer
                        metadata.isManga = parsed.manga ? true : nil
                    } else {
                        metadata.series = parsedTokens.seriesName.isEmpty ? fallbackSeriesName : parsedTokens.seriesName
                        metadata.volume = parsedTokens.volume
                        metadata.issueNumber = parsedTokens.issueNumber
                    }

                    var pdf = ConvertedPDF(
                        name: stem,
                        url: fileURL,
                        pageCount: 0,
                        fileSize: fileSize,
                        metadata: metadata
                    )
                    // Apple Security-Scoped Directory Standard:
                    // On iOS/iPadOS, security scope is granted to the folder root selected in UIDocumentPicker.
                    // Child files inside that folder inherit access while the parent folder's security scope
                    // is active. The volume bookmark provides persistent access across app launches.
                    pdf.sourceMode = .linked(bookmarkData: driveBookmark)
                    tempPDFs.append(pdf)
                }
                return tempPDFs
            }.value

            if !chunkPDFs.isEmpty {
                manager.convertedPDFs.append(contentsOf: chunkPDFs)
                var existingIDs = Set(LibraryService.shared.items.map(\.id))
                var existingPaths = Set(LibraryService.shared.items.map { $0.url.fastCanonicalPath })
                for pdf in chunkPDFs {
                    let p = pdf.url.fastCanonicalPath
                    if !existingIDs.contains(pdf.id) && !existingPaths.contains(p) {
                        existingIDs.insert(pdf.id)
                        existingPaths.insert(p)
                        LibraryService.shared.items.append(pdf)
                    }
                }
                allNewPDFs.append(contentsOf: chunkPDFs)
            }

            await Task.yield()
        }

        guard !allNewPDFs.isEmpty else {
            scanStatus = ""
            return
        }

        scanStatus = "Saving library records…"
        manager.saveLibrary()
        LibraryService.shared.saveLibrary(isStructural: true)
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)

        // Extract visible viewport thumbnails quickly (up to 12 items), leave rest to on-demand scrolling
        let initialBatchCount = min(allNewPDFs.count, 12)
        let initialPDFs = Array(allNewPDFs.prefix(initialBatchCount))
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount <= 4 ? 2 : 3
        await withTaskGroup(of: (Int, Data?).self) { group in
            var inFlight = 0

            for (index, pdf) in initialPDFs.enumerated() {
                if inFlight >= maxConcurrency {
                    if let (idx, data) = await group.next() {
                        if let data, let targetIdx = manager.convertedPDFs.firstIndex(where: { $0.id == initialPDFs[idx].id }) {
                            manager.convertedPDFs[targetIdx].coverImageData = data
                        }
                        inFlight -= 1
                    }
                }
                let url = pdf.url
                let bookmark = pdf.driveBookmarkData
                group.addTask {
                    let data = await Task.detached(priority: .background) { () -> Data? in
                        autoreleasepool {
                            var img: UIImage? = nil
                            if let bookmark {
                                var isStale = false
                                if let resolvedURL = try? URL(
                                    resolvingBookmarkData: bookmark,
                                    options: .withoutUI,
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &isStale
                                ) {
                                    let accessing = resolvedURL.startAccessingSecurityScopedResource()
                                    img = PhysicalFileSystemRouter.extractCoverImageStatic(from: resolvedURL)
                                    if accessing { resolvedURL.stopAccessingSecurityScopedResource() }
                                }
                            } else {
                                img = PhysicalFileSystemRouter.extractCoverImageStatic(from: url)
                            }
                            return img?.jpegData(compressionQuality: 0.7)
                        }
                    }.value
                    return (index, data)
                }
                inFlight += 1
            }
            for await (idx, data) in group {
                if let data, let targetIdx = manager.convertedPDFs.firstIndex(where: { $0.id == initialPDFs[idx].id }) {
                    manager.convertedPDFs[targetIdx].coverImageData = data
                }
            }
        }
        scanStatus = ""
    }

    @objc private func handleStaleBookmark(_ notification: Notification) {
        guard let staleData = notification.object as? Data else { return }
        let manager = conversionManager ?? ConversionManager.shared

        // Attempt resolving and capturing security scope to create a valid fresh bookmark
        var isStale = false
        guard let staleURL = try? URL(
            resolvingBookmarkData: staleData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            Logger.shared.log("LinkedLibraryScanner: Could not resolve stale bookmark — drive may be disconnected", category: "Drive", type: .error)
            return
        }

        let accessing = staleURL.startAccessingSecurityScopedResource()
        defer { if accessing { staleURL.stopAccessingSecurityScopedResource() } }

        var freshBookmark: Data? = try? staleURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if freshBookmark == nil {
            freshBookmark = try? staleURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        guard let refreshed = freshBookmark else {
            Logger.shared.log("LinkedLibraryScanner: Failed to generate refreshed bookmark for '\(staleURL.lastPathComponent)'", category: "Drive", type: .error)
            return
        }

        var didUpdate = false

        // 1. Refresh any linked drive volume bookmarks in AppSettingsManager
        for drive in AppSettingsManager.shared.linkedDrives {
            if drive.volumeBookmarkData == staleData {
                var updated = drive
                updated.volumeBookmarkData = refreshed
                updated.lastSeenDate = Date()
                AppSettingsManager.shared.updateLinkedDrive(updated)
                didUpdate = true
                Logger.shared.log("LinkedLibraryScanner: Refreshed volume bookmark for drive '\(drive.displayName)'", category: "Drive", type: .success)
            }
        }

        // 2. Refresh manager.convertedPDFs
        for idx in manager.convertedPDFs.indices {
            if case .linked(let bm) = manager.convertedPDFs[idx].sourceMode, bm == staleData {
                manager.convertedPDFs[idx].sourceMode = .linked(bookmarkData: refreshed)
                didUpdate = true
                Logger.shared.log("LinkedLibraryScanner: Refreshed bookmark for '\(manager.convertedPDFs[idx].name)'", category: "Drive", type: .info)
            }
        }

        // 3. Refresh LibraryService.shared.items
        for idx in LibraryService.shared.items.indices {
            if case .linked(let bm) = LibraryService.shared.items[idx].sourceMode, bm == staleData {
                LibraryService.shared.items[idx].sourceMode = .linked(bookmarkData: refreshed)
                didUpdate = true
            }
        }

        if didUpdate {
            manager.saveLibrary()
            LibraryService.shared.saveLibrary(isStructural: false)
        }
    }
}
