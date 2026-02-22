import Foundation
import SwiftUI

// ============================================================================
// MARK: - CLOUD MANAGER
// ============================================================================

class CloudManager: ObservableObject {
    static let shared = CloudManager()
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    
    var isICloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
    var iCloudContainerURL: URL? { FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") }
    
    func exportToICloud(pdf: ConvertedPDF, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let containerURL = iCloudContainerURL else { completion(.failure(CloudError.iCloudNotAvailable)); return }
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let destinationURL = containerURL.appendingPathComponent(pdf.url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) { try FileManager.default.removeItem(at: destinationURL) }
                try FileManager.default.copyItem(at: pdf.url, to: destinationURL)
                DispatchQueue.main.async { completion(.success(destinationURL)) }
            } catch { 
                Logger.shared.log("iCloud Export Failed: \(error.localizedDescription)", category: "Network")
                DispatchQueue.main.async { completion(.failure(error)) } 
            }
        }
    }
    
    func exportMultipleToICloud(pdfs: [ConvertedPDF], progressHandler: @escaping (Double, String) -> Void, completion: @escaping (Result<[URL], Error>) -> Void) {
        guard let containerURL = iCloudContainerURL else { completion(.failure(CloudError.iCloudNotAvailable)); return }
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var exportedURLs: [URL] = []
            var lastError: Error?
            for (index, pdf) in pdfs.enumerated() {
                let destinationURL = containerURL.appendingPathComponent(pdf.url.lastPathComponent)
                DispatchQueue.main.async { progressHandler(Double(index) / Double(pdfs.count), "Exporting \(pdf.name)...") }
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) { try FileManager.default.removeItem(at: destinationURL) }
                    try FileManager.default.copyItem(at: pdf.url, to: destinationURL)
                    exportedURLs.append(destinationURL)
                } catch { 
                    Logger.shared.log("iCloud Bulk Export Failed for \(pdf.name): \(error.localizedDescription)", category: "Network")
                    lastError = error 
                }
            }
            DispatchQueue.main.async {
                progressHandler(1.0, "Complete!")
                if let error = lastError, exportedURLs.isEmpty { completion(.failure(error)) }
                else { completion(.success(exportedURLs)) }
            }
        }
    }
}

enum CloudError: LocalizedError {
    case iCloudNotAvailable
    case exportFailed
    case importFailed
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .iCloudNotAvailable: return "iCloud is not available. Please sign in to iCloud in Settings."
        case .exportFailed: return "Failed to export file to cloud storage."
        case .importFailed: return "Failed to import file from cloud storage."
        case .fileNotFound: return "The requested file could not be found."
        }
    }
}
