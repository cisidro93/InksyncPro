import Foundation
import Combine

/// Manages background downloading of cloud files directly into the local InksyncVault.
/// Supports both Dropbox (unauthenticated temporary links) and Google Drive (Bearer token required).
class CloudDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = CloudDownloadManager()

    @Published var activeDownloads: [String: Double] = [:]  // fileID → progress 0...1

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
