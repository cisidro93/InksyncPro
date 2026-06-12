import Foundation

/// Represents a remote file or folder in a cloud storage provider
struct CloudFile: Identifiable, Codable {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date
    let downloadURL: URL? // Used for streaming/downloading
}

/// A unified interface for interacting with cloud storage APIs (e.g., Dropbox, Google Drive)
@MainActor
protocol CloudStorageProvider {
    var providerName: String { get }
    var isConnected: Bool { get }
    
    /// Authenticate the user with the cloud provider (OAuth flow)
    func authenticate() async throws
    
    /// Sign out and clear stored tokens
    func signOut()
    
    /// List contents of a specific folder ID (nil for root)
    func listDirectory(folderID: String?) async throws -> [CloudFile]
    
    /// Get the direct download or streaming URL for a specific file
    func getDownloadURL(fileID: String) async throws -> URL
}
