import Foundation
import Combine

/// Manages background downloading of files from Cloud Providers directly into the local vault
class CloudDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = CloudDownloadManager()
    
    @Published var activeDownloads: [String: Double] = [:] // fileID -> progress 0...1
    
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.antigravity.InksyncPro.clouddownload")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private var downloadTasks: [URLSessionDownloadTask: String] = [:]
    
    private override init() {
        super.init()
    }
    
    func download(fileID: String, from url: URL, targetName: String) {
        var request = URLRequest(url: url)
        // If Google Drive, add auth header if needed (handled in provider URL generation ideally)
        
        let task = urlSession.downloadTask(with: request)
        downloadTasks[task] = fileID
        DispatchQueue.main.async {
            self.activeDownloads[fileID] = 0.0
        }
        task.resume()
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let fileID = downloadTasks[downloadTask] else { return }
        
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.activeDownloads[fileID] = progress
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let fileID = downloadTasks[downloadTask] else { return }
        
        // Move file to App Vault
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let targetURL = docDir.appendingPathComponent("Vault/\(fileID).cbz")
        
        do {
            try? fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.moveItem(at: location, to: targetURL)
            print("Download finished and moved to Vault: \(targetURL)")
            // Here we would dispatch an event to update the ConvertedPDF sourceMode from .cloud to .local
        } catch {
            print("Failed to move downloaded file: \(error)")
        }
        
        DispatchQueue.main.async {
            self.activeDownloads.removeValue(forKey: fileID)
        }
        downloadTasks.removeValue(forKey: downloadTask)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, let downloadTask = task as? URLSessionDownloadTask, let fileID = downloadTasks[downloadTask] {
            print("Download failed: \(error)")
            DispatchQueue.main.async {
                self.activeDownloads.removeValue(forKey: fileID)
            }
            downloadTasks.removeValue(forKey: downloadTask)
        }
    }
}
