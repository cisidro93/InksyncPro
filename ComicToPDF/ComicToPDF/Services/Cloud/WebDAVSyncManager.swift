import Foundation
import Combine

/// Handles uploading large converted EPUB/PDF files directly to WebDAV servers
/// bypassing Amazon's 200MB Send-to-Kindle limit and allowing direct sync to E-Readers
/// like BOOX, Supernote, and Kobo (via third-party integrations).
@MainActor
final class WebDAVSyncManager: NSObject, ObservableObject, URLSessionTaskDelegate, URLSessionDataDelegate, Sendable {
    static let shared = WebDAVSyncManager()
    
    @Published var isSyncing: Bool = false
    @Published var syncProgress: Double = 0.0
    @Published var lastSyncStatus: String = ""
    
    private var session: URLSession!
    private var activeTasks: [Int: URLSessionUploadTask] = [:]
    private var taskContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var taskFiles: [Int: URL] = [:]
    
    private override init() {
        super.init()
        // 🚨 COMPETITOR FIX: Enforce background daemon configuration to survive Springboard suspension.
        let config = URLSessionConfiguration.background(withIdentifier: "com.inksyncpro.webdav.\(UUID().uuidString)")
        config.isDiscretionary = false // Run immediately, don't wait for WiFi/Power
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 300 // 5 minutes for large files
        config.timeoutIntervalForResource = 3600 // 1 hour total
        
        // Background sessions require delegate assignment, not closure callbacks.
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }
    
    /// Starts a WebDAV PUT request to upload a given file to a target server
    func uploadToWebDAV(fileURL: URL, serverURL: URL, username: String?, password: String?) async throws {
        self.isSyncing = true
        self.syncProgress = 0.0
        self.lastSyncStatus = "Connecting to \(serverURL.host ?? "Server")..."
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CloudSyncError.fileNotFound
        }
        
        let targetURL = serverURL.appendingPathComponent(fileURL.lastPathComponent)
        var request = URLRequest(url: targetURL)
        request.httpMethod = "PUT"
        
        // Basic Authentication
        if let user = username, let pass = password, !user.isEmpty {
            let loginString = String(format: "%@:%@", user, pass)
            if let loginData = loginString.data(using: .utf8) {
                let base64LoginString = loginData.base64EncodedString()
                request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
            }
        }
        
        // Set content type
        let ext = fileURL.pathExtension.lowercased()
        if ext == "epub" {
            request.setValue("application/epub+zip", forHTTPHeaderField: "Content-Type")
        } else if ext == "pdf" {
            request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        } else if ext == "cbz" {
            request.setValue("application/vnd.comicbook+zip", forHTTPHeaderField: "Content-Type")
        }
        
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    let task = self.session.uploadTask(with: request, fromFile: fileURL)
                    self.activeTasks[task.taskIdentifier] = task
                    self.taskContinuations[task.taskIdentifier] = continuation
                    self.taskFiles[task.taskIdentifier] = fileURL
                    
                    task.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelAllSyncs()
            }
        }
    }
    
    // MARK: - URLSession Delegates
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // Track Background Upload Progress Live
        let progress = totalBytesExpectedToSend > 0 ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0
        Task { @MainActor in
            self.syncProgress = progress
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        let response = task.response
        Task { @MainActor in
            let fileURL = self.taskFiles[taskID]
            
            defer {
                self.activeTasks.removeValue(forKey: taskID)
                self.taskContinuations.removeValue(forKey: taskID)
                self.taskFiles.removeValue(forKey: taskID)
                if self.activeTasks.isEmpty {
                    self.isSyncing = false
                }
            }
            
            if let error = error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled {
                    self.lastSyncStatus = "Upload Cancelled"
                    self.taskContinuations[taskID]?.resume(throwing: CancellationError())
                } else {
                    self.lastSyncStatus = "Upload Failed: \(error.localizedDescription)"
                    self.taskContinuations[taskID]?.resume(throwing: error)
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    self.syncProgress = 1.0
                    self.lastSyncStatus = fileURL != nil ? "Successfully uploaded \(fileURL!.lastPathComponent)" : "Upload Complete"
                    self.taskContinuations[taskID]?.resume(returning: ())
                } else {
                    self.lastSyncStatus = "Server Error: \(httpResponse.statusCode)"
                    self.taskContinuations[taskID]?.resume(throwing: CloudSyncError.httpError(statusCode: httpResponse.statusCode))
                }
            } else {
                self.lastSyncStatus = "Server returned an unrecognizable response."
                self.taskContinuations[taskID]?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
    
    // ✅ Emergency kill switch protecting against background runaway UI states
    func cancelAllSyncs() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        
        for cont in taskContinuations.values {
            cont.resume(throwing: CancellationError())
        }
        taskContinuations.removeAll()
        taskFiles.removeAll()
        
        isSyncing = false
        syncProgress = 0.0
        lastSyncStatus = "All pending uploads terminated."
    }
}

enum CloudSyncError: LocalizedError {
    case fileNotFound
    case invalidURL
    case httpError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "The source file was not found on disk."
        case .invalidURL: return "The target server URL is invalid."
        case .httpError(let code): return "The server responded with an error code: \(code)."
        }
    }
}
