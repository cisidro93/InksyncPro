// ============================================================================
// External Storage Manager
// ============================================================================
// Supports: USB drives, SD cards, network drives, iCloud Drive
// Copy this entire file into your Antigravity project
// ============================================================================

import UIKit
import UniformTypeIdentifiers

class ExternalStorageManager: NSObject {
    
    static let shared = ExternalStorageManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Import from External Storage
    
    /// Select a single file from external storage (USB, SD card, network drive)
    func selectFileFromExternalStorage(
        from viewController: UIViewController,
        completion: @escaping (URL?) -> Void
    ) {
        let types: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .data,
            UTType(filenameExtension: "cbr") ?? .data,
            UTType(filenameExtension: "cb7") ?? .data,
            UTType(filenameExtension: "epub") ?? .epub,
            .pdf
        ]
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        
        self.importCompletion = completion
        viewController.present(picker, animated: true)
    }
    
    /// Select multiple files from external storage
    func selectMultipleFilesFromExternalStorage(
        from viewController: UIViewController,
        completion: @escaping ([URL]) -> Void
    ) {
        let types: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .data,
            UTType(filenameExtension: "cbr") ?? .data,
            UTType(filenameExtension: "cb7") ?? .data,
            UTType(filenameExtension: "epub") ?? .epub,
            .pdf
        ]
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        
        self.importMultipleCompletion = completion
        viewController.present(picker, animated: true)
    }
    
    /// Select a folder from external storage
    func selectFolderFromExternalStorage(
        from viewController: UIViewController,
        completion: @escaping (URL?) -> Void
    ) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .directory])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        
        self.importFolderCompletion = completion
        viewController.present(picker, animated: true)
    }
    
    // MARK: - Export to External Storage
    
    /// Export a single file to external storage
    func exportToExternalStorage(
        fileURL: URL,
        suggestedName: String? = nil,
        from viewController: UIViewController,
        completion: @escaping (Bool, URL?) -> Void
    ) {
        // Copy to temp location with suggested name if provided
        let tempURL: URL
        if let name = suggestedName {
            let tempDir = FileManager.default.temporaryDirectory
            tempURL = tempDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: fileURL, to: tempURL)
        } else {
            tempURL = fileURL
        }
        
        let picker = UIDocumentPickerViewController(forExporting: [tempURL])
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        
        self.exportCompletion = completion
        viewController.present(picker, animated: true)
    }
    
    /// Export multiple files to external storage
    func exportMultipleToExternalStorage(
        fileURLs: [URL],
        from viewController: UIViewController,
        completion: @escaping (Bool) -> Void
    ) {
        let picker = UIDocumentPickerViewController(forExporting: fileURLs)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        
        self.exportMultipleCompletion = completion
        viewController.present(picker, animated: true)
    }
    
    // MARK: - Helper Methods
    
    /// Copy file from external storage to app's local storage
    func copyToAppStorage(_ externalURL: URL) throws -> URL {
        let accessing = externalURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Copy to app's documents directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsURL.appendingPathComponent(externalURL.lastPathComponent)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)
        
        // Copy file
        try FileManager.default.copyItem(at: externalURL, to: destinationURL)
        
        return destinationURL
    }
    
    /// Access an external file securely (for reading without copying)
    func accessSecureFile(_ url: URL, operation: (URL) -> Void) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        operation(url)
    }
    
    // MARK: - Private Properties
    
    private var importCompletion: ((URL?) -> Void)?
    private var importMultipleCompletion: (([URL]) -> Void)?
    private var importFolderCompletion: ((URL?) -> Void)?
    private var exportCompletion: ((Bool, URL?) -> Void)?
    private var exportMultipleCompletion: ((Bool) -> Void)?
}

// MARK: - UIDocumentPickerDelegate

extension ExternalStorageManager: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        
        if let completion = importFolderCompletion {
            // Folder import
            guard let url = urls.first else {
                completion(nil)
                importFolderCompletion = nil
                return
            }
            completion(url)
            importFolderCompletion = nil
            
        } else if let completion = importCompletion {
            // Single file import
            guard let url = urls.first else {
                completion(nil)
                importCompletion = nil
                return
            }
            
            // Copy to app storage for processing
            do {
                let localURL = try copyToAppStorage(url)
                completion(localURL)
            } catch {
                print("❌ Failed to copy file: \(error)")
                completion(nil)
            }
            importCompletion = nil
            
        } else if let completion = importMultipleCompletion {
            // Multiple file import
            var copiedURLs: [URL] = []
            
            for url in urls {
                do {
                    let localURL = try copyToAppStorage(url)
                    copiedURLs.append(localURL)
                } catch {
                    print("❌ Failed to copy \(url.lastPathComponent): \(error)")
                }
            }
            
            completion(copiedURLs)
            importMultipleCompletion = nil
            
        } else if let completion = exportCompletion {
            // Export completion
            completion(true, urls.first)
            exportCompletion = nil
            
        } else if let completion = exportMultipleCompletion {
            // Multiple export completion
            completion(true)
            exportMultipleCompletion = nil
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        importCompletion?(nil)
        importMultipleCompletion?([])
        importFolderCompletion?(nil)
        exportCompletion?(false, nil)
        exportMultipleCompletion?(false)
        
        importCompletion = nil
        importMultipleCompletion = nil
        importFolderCompletion = nil
        exportCompletion = nil
        exportMultipleCompletion = nil
    }
}
