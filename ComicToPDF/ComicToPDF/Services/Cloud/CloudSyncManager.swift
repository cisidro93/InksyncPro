import Foundation
import Combine

/// Handles uploading large converted EPUB/PDF files directly to WebDAV servers
/// bypassing Amazon's 200MB Send-to-Kindle limit and allowing direct sync to E-Readers
/// like BOOX, Supernote, and Kobo (via third-party integrations).
class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()
    
    @Published var isSyncing: Bool = false
    @Published var syncProgress: Double = 0.0
    @Published var lastSyncStatus: String = ""
    
    private var session: URLSession
    private var activeTask: URLSessionUploadTask?
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes for large files
        config.timeoutIntervalForResource = 3600 // 1 hour total
        self.session = URLSession(configuration: config)
    }
    
    /// Starts a WebDAV PUT request to upload a given file to a target server
    func uploadToWebDAV(fileURL: URL, serverURL: URL, username: String?, password: String?) async throws {
        Task { @MainActor in
            self.isSyncing = true
            self.syncProgress = 0.0
            self.lastSyncStatus = "Connecting to \(serverURL.host ?? "Server")..."
        }
        
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
        
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let error = error {
                    Task { @MainActor in
                        self.isSyncing = false
                        self.lastSyncStatus = "Upload Failed: \(error.localizedDescription)"
                    }
                    continuation.resume(throwing: error)
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    if (200...299).contains(httpResponse.statusCode) {
                        Task { @MainActor in
                            self.isSyncing = false
                            self.syncProgress = 1.0
                            self.lastSyncStatus = "Successfully uploaded \(fileURL.lastPathComponent)"
                        }
                        continuation.resume(returning: ())
                    } else {
                        Task { @MainActor in
                            self.isSyncing = false
                            self.lastSyncStatus = "Server Error: \(httpResponse.statusCode)"
                        }
                        continuation.resume(throwing: CloudSyncError.httpError(statusCode: httpResponse.statusCode))
                    }
                }
            }
            
            // Note: In a real implementation with accurate progress tracking,
            // we would implement URLSessionTaskDelegate to track bytes sent.
            // For now, this utilizes async/await with the basic closure.
            
            task.resume()
        }
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
