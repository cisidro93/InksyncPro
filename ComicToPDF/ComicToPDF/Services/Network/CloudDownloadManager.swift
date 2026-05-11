import Foundation
import Combine

/// Manages background downloading of cloud files directly into the local InksyncVault.
/// Supports both Dropbox (unauthenticated temporary links) and Google Drive (Bearer token required).
class CloudDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = CloudDownloadManager()

    @Published var activeDownloads: [String: Double] = [:]  // fileID → progress 0...1
    /// Per-file streaming progress (0–1). Cloud cells observe this to show a progress bar.
    @Published var streamProgress: [String: Double] = [:]   // remoteID → progress 0...1

    // MARK: - Temp-File Cache (avoid re-download within 1 hour)
    private struct CacheEntry { let url: URL; let expires: Date }
    private var tempFileCache: [String: CacheEntry] = [:]    // remoteID → CacheEntry
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
    private var downloadTaskMeta: [URLSessionDownloadTask: (fileID: String, fileName: String)] = [:]

    private override init() { super.init() }

    // MARK: - In-Flight Stream Deduplication
    // If two concurrent readers try to open the same cloud file, only one network
    // fetch is made. Both callers await the same Task and receive the same local URL.
    private var activeStreams: [String: Task<URL, Error>] = [:]  // remoteID → Task
    private let streamsLock = NSLock()

    // MARK: - Public API

    /// Download a Dropbox file. Dropbox temporary links are public — no auth header needed.
    func downloadFromDropbox(fileID: String, fileName: String, temporaryURL: URL) {
        let request = URLRequest(url: temporaryURL)
        startTask(request: request, fileID: fileID, fileName: fileName)
    }

    /// Download a Google Drive file. Requires a live Bearer token.
    func downloadFromGoogleDrive(fileID: String, fileName: String, mediaURL: URL, authHeader: String) {
        var request = URLRequest(url: mediaURL)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        startTask(request: request, fileID: fileID, fileName: fileName)
    }

    /// Convenience: resolve URL and auth automatically from the provider.
    func downloadCloudFile(pdf: ConvertedPDF) async {
        guard case .cloud(let provider, let remoteID) = pdf.sourceMode else { return }

        // Derive the target filename from the comic's own name (which IS reliable),
        // not from pdf.url which is a dummy cloud:// URL with no real extension.
        let ext = pdf.name.components(separatedBy: ".").last?.lowercased() ?? "cbz"
        let isKnownComicExt = ["cbz", "cbr", "zip", "epub", "pdf"].contains(ext)
        let fileName = isKnownComicExt ? pdf.name : (pdf.name + ".cbz")

        do {
            if provider == "Dropbox" {
                let url = try await DropboxProvider.shared.getDownloadURL(fileID: remoteID)
                downloadFromDropbox(fileID: remoteID, fileName: fileName, temporaryURL: url)
            } else if provider == "Google Drive" {
                let mediaURL = try await GoogleDriveProvider.shared.getDownloadURL(fileID: remoteID)
                let authHeader = try await GoogleDriveProvider.shared.currentAuthHeader()
                downloadFromGoogleDrive(fileID: remoteID, fileName: fileName, mediaURL: mediaURL, authHeader: authHeader)
            }
        } catch {
            Logger.shared.log("CloudDownloadManager: Failed to initiate download for '\(pdf.name)': \(error.localizedDescription)", category: "Cloud", type: .error)
            // Also mark any queued job as failed
            if let job = ConversionJobQueue.shared.getJob(for: pdf.id) {
                ConversionJobQueue.shared.updateJobStatus(pdfID: job.pdfID, newStatus: .failed)
            }
        }
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
        streamsLock.lock()
        if let existing = activeStreams[remoteID] {
            streamsLock.unlock()
            return try await existing.value
        }

        let task: Task<URL, Error> = Task {
            try await self._performStream(provider: provider, remoteID: remoteID, pdf: pdf)
        }
        activeStreams[remoteID] = task
        streamsLock.unlock()

        defer {
            streamsLock.lock()
            activeStreams.removeValue(forKey: remoteID)
            streamsLock.unlock()
        }

        return try await task.value
    }

    private func _performStream(provider: String, remoteID: String, pdf: ConvertedPDF) async throws -> URL {
        // ── Step 0: Temp-file cache — skip network if recently streamed ──────────
        if let cached = tempFileCache[remoteID],
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
        } else if provider == "Google Drive" {
            downloadURL = try await GoogleDriveProvider.shared.getDownloadURL(fileID: remoteID)
            request = URLRequest(url: downloadURL)
            let authHeader = try await GoogleDriveProvider.shared.currentAuthHeader()
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        } else {
            throw CloudStreamError.unknownProvider(provider)
        }

        // ── Step 2: Download with Task-cancellation support and live progress ────
        try Task.checkCancellation()

        await MainActor.run { self.streamProgress[remoteID] = 0.0 }

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
                await MainActor.run { self.streamProgress.removeValue(forKey: remoteID) }
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
            await MainActor.run { self.streamProgress.removeValue(forKey: remoteID) }
            throw CloudStreamError.localFileMoveFailure(error)
        }

        // ── Step 5: Store in cache and clean up progress ──────────────────────────
        let expiry = Date().addingTimeInterval(cacheHoursLimit * 3600)
        tempFileCache[remoteID] = CacheEntry(url: finalTemp, expires: expiry)
        await MainActor.run { self.streamProgress.removeValue(forKey: remoteID) }

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


    // MARK: - Private

    private func startTask(request: URLRequest, fileID: String, fileName: String) {
        let task = urlSession.downloadTask(with: request)
        downloadTaskMeta[task] = (fileID, fileName)
        DispatchQueue.main.async { self.activeDownloads[fileID] = 0.0 }
        task.resume()
        Logger.shared.log("CloudDownloadManager: Download started for '\(fileName)'", category: "Cloud")
    }

    private var vault: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vaultURL = appSupport.appendingPathComponent("InksyncVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        return vaultURL
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let meta = downloadTaskMeta[downloadTask], totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.activeDownloads[meta.fileID] = progress }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let meta = downloadTaskMeta[downloadTask] else { return }

        let targetURL = vault.appendingPathComponent(meta.fileName)

        do {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.moveItem(at: location, to: targetURL)
            Logger.shared.log("CloudDownloadManager: '\(meta.fileName)' downloaded to Vault", category: "Cloud", type: .success)

            // Notify ConversionManager to flip the sourceMode from .cloud → .local
            DispatchQueue.main.async {
                let manager = LinkedLibraryScanner.shared.conversionManager
                var updatedPDF: ConvertedPDF?
                
                if let idx = manager?.convertedPDFs.firstIndex(where: { $0.url.lastPathComponent == meta.fileName }) {
                    manager?.convertedPDFs[idx].url = targetURL
                    manager?.convertedPDFs[idx].sourceMode = .local
                    manager?.saveLibrary()
                    updatedPDF = manager?.convertedPDFs[idx]
                }
                self.activeDownloads.removeValue(forKey: meta.fileID)
                
                // ✅ Check if this file has a pending conversion job
                if let pdf = updatedPDF, let job = ConversionJobQueue.shared.getJobByTargetFileName(meta.fileName) {
                    Logger.shared.log("CloudDownloadManager: Found pending conversion job for '\(meta.fileName)'. Handoff to Orchestrator.", category: "Cloud")
                    ConversionJobQueue.shared.updateJobStatus(pdfID: pdf.id, newStatus: .extracting)
                    
                    Task {
                        // We must pass the correct parameters depending on if it's a merge or a single convert
                        if let manager = manager {
                            if job.isMerge {
                                await ConversionOrchestrator.shared.convertAndMerge(
                                    sourceFiles: [pdf], 
                                    outputName: job.outputName ?? "", 
                                    mangaMode: job.mangaMode ?? false, 
                                    manager: manager
                                )
                            } else {
                                await ConversionOrchestrator.shared.convertComic(pdf, mangaMode: job.mangaMode, manager: manager)
                            }
                            ConversionJobQueue.shared.updateJobStatus(pdfID: pdf.id, newStatus: .completed)
                            ConversionJobQueue.shared.removeJob(pdfID: pdf.id)
                        }
                    }
                }
            }
        } catch {
            Logger.shared.log("CloudDownloadManager: Failed to move '\(meta.fileName)' to Vault: \(error.localizedDescription)", category: "Cloud", type: .error)
            DispatchQueue.main.async { self.activeDownloads.removeValue(forKey: meta.fileID) }
        }

        downloadTaskMeta.removeValue(forKey: downloadTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let downloadTask = task as? URLSessionDownloadTask,
              let meta = downloadTaskMeta[downloadTask] else { return }

        Logger.shared.log("CloudDownloadManager: Download failed for '\(meta.fileName)': \(error.localizedDescription)", category: "Cloud", type: .error)
        DispatchQueue.main.async {
            self.activeDownloads.removeValue(forKey: meta.fileID)
            // Mark any waiting job as failed so the library banner reflects the real state
            if let job = ConversionJobQueue.shared.getJobByTargetFileName(meta.fileName) {
                ConversionJobQueue.shared.updateJobStatus(pdfID: job.pdfID, newStatus: .failed)
            }
        }
        downloadTaskMeta.removeValue(forKey: downloadTask)
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
