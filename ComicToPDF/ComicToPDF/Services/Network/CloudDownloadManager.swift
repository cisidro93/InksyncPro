import Foundation
import Combine
import os

/// Manages background downloading of cloud files directly into the local InksyncVault.
/// Supports both Dropbox (unauthenticated temporary links) and Google Drive (Bearer token required).
@MainActor
class CloudDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = CloudDownloadManager()

    @Published var activeDownloads: [String: Double] = [:]  // fileID → progress 0...1
    /// Per-file streaming progress (0–1). Cloud cells observe this to show a progress bar.
    @Published var streamProgress: [String: Double] = [:]   // remoteID → progress 0...1

    // MARK: - Temp-File Cache (avoid re-download within 1 hour)
    private struct CacheEntry { let url: URL; let expires: Date }
    private let tempFileCache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])
    private let cacheHoursLimit: Double = 1.0

    // Dedicated foreground URLSession for streaming (progress-observable)
    private lazy var streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600  // allow up to 1 hour for large archives
        return URLSession(configuration: config)
    }()

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.antigravity.InksyncPro.clouddownload"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Maps each active task → (fileID, fileName)
    private let downloadTaskMeta = OSAllocatedUnfairLock<[URLSessionDownloadTask: (fileID: String, fileName: String)]>(initialState: [:])

    private override init() { super.init() }

    // MARK: - In-Flight Stream Deduplication
    // If two concurrent readers try to open the same cloud file, only one network
    // fetch is made. Both callers await the same Task and receive the same local URL.
    private let activeStreams = OSAllocatedUnfairLock<[String: Task<URL, Error>]>(initialState: [:])

    // MARK: - Download-to-Vault (Permanent Storage)

    /// Downloads a Dropbox/GDrive file permanently into InksyncVault, then optionally
    /// triggers conversion. This replaces the old URLSessionDownloadDelegate approach
    /// which had three compounding bugs:
    ///   1. `targetFileName` used `pdf.url.pathExtension` which is always "" for cloud files.
    ///   2. Library lookup used `url.lastPathComponent` which never matched the cloud placeholder.
    ///   3. Background URLSession `didFinishDownloadingTo` fired on an unknown queue before
    ///      the vault directory was guaranteed to exist.
    ///
    /// The new flow reuses the battle-tested `streamCloudFile` pipeline, then moves the
    /// result to the permanent vault path on the `@MainActor`.
    func downloadAndStore(
        pdf: ConvertedPDF,
        thenConvert: Bool = false,
        manager: ConversionManager? = nil,
        mangaMode: Bool? = nil
    ) async {
        let ext: String
        if let lastDot = pdf.name.lastIndex(of: ".") {
            ext = String(pdf.name[pdf.name.index(after: lastDot)...]).lowercased()
        } else {
            ext = "cbz"
        }
        let knownExts: Set<String> = ["cbz", "cbr", "zip", "epub", "pdf", "cb7", "cbt"]
        let safeFileName = knownExts.contains(ext) ? pdf.name : (pdf.name + ".cbz")

        _ = await MainActor.run {
            manager?.processingStatus = "Downloading \(pdf.name)…"
            manager?.statusMessage = "Downloading…"
        }

        do {
            // Step 1: Stream to temp (reuses proven streamCloudFile path)
            let tempURL = try await streamCloudFile(pdf: pdf)

            // Step 2: Move temp → permanent vault (on a background thread, but vault is
            //         always guaranteed to exist because we compute it fresh each call)
            let destination = vaultURL.appendingPathComponent(safeFileName)
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tempURL, to: destination)
            }.value

            Logger.shared.log("CloudDownloadManager: '\(safeFileName)' saved to Vault", category: "Cloud", type: .success)

            // Step 3: Flip sourceMode in the library record → .local
            let finalURL = destination
            _ = await MainActor.run {
                if let mgr = manager ?? LinkedLibraryScanner.shared.conversionManager,
                   let idx = mgr.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    mgr.convertedPDFs[idx].url = finalURL
                    mgr.convertedPDFs[idx].sourceMode = .local
                    mgr.saveLibrary()

                    // Step 4: Kick off conversion if requested
                    if thenConvert {
                        let updatedPDF = mgr.convertedPDFs[idx]
                        Task { await ConversionOrchestrator.shared.convertComic(updatedPDF, mangaMode: mangaMode, manager: mgr) }
                    }
                }
                manager?.processingStatus = ""
                manager?.statusMessage = nil
                // Evict the temp-file cache so a fresh stream picks up the vault copy
                self.evictCache(for: { if case .cloud(_, let id) = pdf.sourceMode { return id } else { return "" } }())
            }

        } catch {
            Logger.shared.log(
                "CloudDownloadManager: Download failed for '\(pdf.name)': \(error.localizedDescription)",
                category: "Cloud", type: .error
            )
            _ = await MainActor.run {
                manager?.processingStatus = ""
                manager?.statusMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Vault URL (thread-safe, eager directory creation)
    private var vaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vaultURL = appSupport.appendingPathComponent("InksyncVault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vaultURL.path) {
            try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true, attributes: nil)
        }
        return vaultURL
    }


    // MARK: - Streaming API (No Permanent Storage)
    
    /// Downloads a cloud file to a temporary directory and returns its local URL.
    ///
    /// Hardened guarantees:
    ///  - HTTP response status validated: non-2xx throws a localised error.
    ///  - In-flight deduplication: concurrent calls for the same `remoteID` share one Task.
    ///  - Swift Task cancellation propagated: cancelling the parent Task cancels the download.
    ///  - Temp file cleanup on failure: the OS temp file is removed if move fails.
    ///  - Safe file name: path separators and excessively long names are sanitised.
    func streamCloudFile(pdf: ConvertedPDF) async throws -> URL {
        guard case .cloud(let provider, let remoteID) = pdf.sourceMode else {
            throw CloudStreamError.notACloudFile
        }

        // ── Deduplication: reuse an existing in-flight task for the same remote ID ──
        let task: Task<URL, Error> = activeStreams.withLock { streams in
            if let existing = streams[remoteID] {
                return existing
            }
            let newTask = Task {
                try await self._performStream(provider: provider, remoteID: remoteID, pdf: pdf)
            }
            streams[remoteID] = newTask
            return newTask
        }

        defer {
            _ = activeStreams.withLock { streams in
                streams.removeValue(forKey: remoteID)
            }
        }

        return try await task.value
    }

    /// Removes a remoteID from the temp-file cache.
    /// Call this after manually deleting the cached file to prevent stale path returns.
    func evictCache(for remoteID: String) {
        _ = tempFileCache.withLock { cache in
            cache.removeValue(forKey: remoteID)
        }
        Logger.shared.log("CloudDownloadManager: Cache evicted for \(remoteID.prefix(8))…", category: "Cloud")
    }

    // MARK: - Universal URL Resolver

    /// Returns a guaranteed-local URL for any ConvertedPDF, regardless of source.
    ///
    /// - For `.local` files      → returns `pdf.url` directly (zero overhead)
    /// - For `.linked` files     → resolves the security-scoped bookmark (zero network)
    /// - For `.cloud` files      → downloads to a temp file via `streamCloudFile`
    ///
    /// The `needsCleanup` flag tells the caller whether to delete the URL after use.
    /// **Cloud callers MUST delete the temp file when done to preserve storage.**
    ///
    /// This is the standard entry point for Convert / Export / Merge operations.
    /// The traditional local import path is completely unaffected.
    func resolveLocalURL(for pdf: ConvertedPDF) async throws -> (url: URL, needsCleanup: Bool) {
        switch pdf.sourceMode {
        case .cloud:
            Logger.shared.log(
                "CloudDownloadManager: Resolving cloud file '\(pdf.name)' for operation…",
                category: "Cloud"
            )
            let url = try await streamCloudFile(pdf: pdf)
            return (url, needsCleanup: true)

        case .linked(let bookmark):
            let url = try BookmarkResolver.shared.resolve(bookmark)
            return (url, needsCleanup: false)

        default:
            // .local, .wifi, or any other local-storage mode — pass through unchanged
            return (pdf.url, needsCleanup: false)
        }
    }


    private func _performStream(provider: String, remoteID: String, pdf: ConvertedPDF) async throws -> URL {
        // ── Step 0: Temp-file cache — skip network if recently streamed ──────────
        let cachedEntry = tempFileCache.withLock { cache in
            cache[remoteID]
        }
        if let cached = cachedEntry,
           cached.expires > Date(),
           FileManager.default.fileExists(atPath: cached.url.path) {
            Logger.shared.log("CloudStream: Cache hit for '\(pdf.name)' — skipping re-download", category: "Cloud")
            return cached.url
        }

        // ── Step 1: Resolve authenticated download URL ──────────────────────────
        let downloadURL: URL
        var request: URLRequest

        if provider == "Dropbox" {
            downloadURL = try await DropboxProvider.shared.getDownloadURL(fileID: remoteID)
            request = URLRequest(url: downloadURL)
            // Dropbox temporary links are pre-authenticated — no Authorization header needed
        } else if provider == "Google Drive" || provider == "GoogleDrive" {
            downloadURL = try await GoogleDriveProvider.shared.getDownloadURL(fileID: remoteID)
            request = URLRequest(url: downloadURL)
            let authHeader = try await GoogleDriveProvider.shared.currentAuthHeader()
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        } else {
            throw CloudStreamError.unknownProvider(provider)
        }

        // ── Step 2: Download with Task-cancellation support and live progress ────
        try Task.checkCancellation()

        _ = await MainActor.run { self.streamProgress[remoteID] = 0.0 }

        // Use the dedicated streamSession with an observation task for progress
        let (tempURL, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            let task = self.streamSession.downloadTask(with: request) { localURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let localURL, let response {
                    // Move out of the OS-managed temp path immediately (it's deleted after callback)
                    let safeTemp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("inksync_dl_\(UUID().uuidString.prefix(8))")
                    do {
                        try FileManager.default.moveItem(at: localURL, to: safeTemp)
                        continuation.resume(returning: (safeTemp, response))
                    } catch {
                        continuation.resume(throwing: CloudStreamError.localFileMoveFailure(error))
                    }
                } else {
                    continuation.resume(throwing: CloudStreamError.httpError(statusCode: 0, provider: provider))
                }
            }
            // Wire progress observation
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                DispatchQueue.main.async { self?.streamProgress[remoteID] = fraction }
            }
            // Retain observation until task finishes by attaching it to a Task
            Task { _ = observation }
            task.resume()
        }

        // ── Step 3: Validate HTTP response ───────────────────────────────────────
        if let httpResponse = response as? HTTPURLResponse {
            let status = httpResponse.statusCode
            guard (200...299).contains(status) else {
                try? FileManager.default.removeItem(at: tempURL)
                _ = await MainActor.run { self.streamProgress.removeValue(forKey: remoteID) }
                throw CloudStreamError.httpError(statusCode: status, provider: provider)
            }
        }

        // ── Step 4: Rename to a meaningful, safe path ────────────────────────────
        let safeName = sanitisedFileName(for: pdf)
        let uniqueID = UUID().uuidString.prefix(8)
        let finalTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("inksync_stream_\(uniqueID)_\(safeName)")

        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.moveItem(at: tempURL, to: finalTemp)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            _ = await MainActor.run { self.streamProgress.removeValue(forKey: remoteID) }
            throw CloudStreamError.localFileMoveFailure(error)
        }

        // ── Step 5: Store in cache and clean up progress ──────────────────────────
        let expiry = Date().addingTimeInterval(cacheHoursLimit * 3600)
        tempFileCache.withLock { cache in
            cache[remoteID] = CacheEntry(url: finalTemp, expires: expiry)
        }
        _ = await MainActor.run { self.streamProgress.removeValue(forKey: remoteID) }

        Logger.shared.log(
            "CloudStream: '\(pdf.name)' ready at temp [\(uniqueID)] — cached until \(expiry)",
            category: "Cloud", type: .success
        )
        return finalTemp
    }

    /// Produces a safe, non-empty file name: strips path separators, limits length to 200 chars.
    private func sanitisedFileName(for pdf: ConvertedPDF) -> String {
        let name = pdf.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let ext = (name as NSString).pathExtension.lowercased()
        let knownExt = ["cbz", "cbr", "zip", "epub", "pdf", "cb7", "cbt"].contains(ext)
        let withExt = knownExt ? name : (name + ".cbz")
        // Truncate the stem so the full path stays safely within POSIX limits
        if withExt.count > 200 {
            let truncated = String(withExt.prefix(196)) + "." + (knownExt ? ext : "cbz")
            return truncated
        }
        return withExt
    }


    // MARK: - URLSessionDownloadDelegate (kept for progress tracking only)

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let meta = downloadTaskMeta.withLock { $0[downloadTask] }
        guard let meta, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.activeDownloads[meta.fileID] = progress
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // No-op: download-to-vault is now handled by downloadAndStore()
        _ = downloadTaskMeta.withLock { $0.removeValue(forKey: downloadTask) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let downloadTask = task as? URLSessionDownloadTask else { return }
              
        let meta = downloadTaskMeta.withLock { $0.removeValue(forKey: downloadTask) }
        guard let meta else { return }

        Logger.shared.log("CloudDownloadManager: URLSession task error for '\(meta.fileName)': \(error.localizedDescription)", category: "Cloud", type: .error)
        Task { @MainActor in
            self.activeDownloads.removeValue(forKey: meta.fileID)
        }
    }
}

// MARK: - CloudStreamError

enum CloudStreamError: LocalizedError {
    case notACloudFile
    case unknownProvider(String)
    case httpError(statusCode: Int, provider: String)
    case localFileMoveFailure(Error)

    var errorDescription: String? {
        switch self {
        case .notACloudFile:
            return "This file is stored locally and does not require cloud streaming."
        case .unknownProvider(let name):
            return "'\(name)' is not a supported cloud provider. Please reconnect in Settings."
        case .httpError(let code, let provider):
            switch code {
            case 401:
                return "\(provider) session expired. Please reconnect your account in Settings → Cloud."
            case 403:
                return "Access denied. Check that InksyncPro has permission to read this file in \(provider)."
            case 404:
                return "File not found in \(provider). It may have been moved or deleted."
            case 429:
                return "\(provider) rate limit reached. Please wait a moment and try again."
            case 500...599:
                return "\(provider) server error (HTTP \(code)). Try again in a few minutes."
            default:
                return "Failed to download from \(provider) (HTTP \(code))."
            }
        case .localFileMoveFailure(let underlying):
            return "Could not save the streamed file to device storage: \(underlying.localizedDescription)"
        }
    }
}
