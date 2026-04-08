import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS File/Folder picker globally, completely bypassing SwiftUI `.sheet`
/// bugs that cause thread locks or frozen "Open" buttons.
final class ImportCoordinator: NSObject, UIDocumentPickerDelegate {

    enum ImportType {
        case files
        case folder
        case json // For settings/exports
        case smartList // For cbl, csv, md, txt
        case unified // Universal hybrid file and folder picker
    }

    private static var live: ImportCoordinator?
    private var completion: (([URL]) -> Void)?
    private var currentType: ImportType = .files

    private override init() {}

    /// Present the picker from the topmost active view controller.
    static func present(type: ImportType = .files, completion: @escaping ([URL]) -> Void) {
        let coordinator = ImportCoordinator()
        coordinator.completion = completion
        coordinator.currentType = type
        ImportCoordinator.live = coordinator

        guard let rootVC = ImportCoordinator.topViewController() else {
            Logger.shared.log("ImportCoordinator: Could not find root view controller.", category: "System", type: .error)
            completion([])
            ImportCoordinator.live = nil
            return
        }

        let supportedTypes: [UTType]
        switch type {
        case .files:
            supportedTypes = [
                UTType(filenameExtension: "cbz") ?? .zip,
                UTType(filenameExtension: "cbr") ?? .archive,
                UTType(filenameExtension: "cb7") ?? .archive,
                .epub, .pdf, .zip, .archive
            ]
        case .unified:
            supportedTypes = [
                UTType(filenameExtension: "cbz") ?? .zip,
                UTType(filenameExtension: "cbr") ?? .archive,
                UTType(filenameExtension: "cb7") ?? .archive,
                .epub, .pdf, .zip, .archive, .folder
            ]
        case .folder:
            supportedTypes = [.folder]
        case .json:
            supportedTypes = [.json]
        case .smartList:
            supportedTypes = [
                .item, .content, .data, .plainText, .commaSeparatedText, .text,
                UTType(filenameExtension: "cbl") ?? .xml,
                UTType(filenameExtension: "csv") ?? .commaSeparatedText,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "txt") ?? .plainText
            ]
        }
        
        let picker: UIDocumentPickerViewController
        if type == .folder {
            let folderTypes: [UTType] = [.folder, .directory]
            picker = UIDocumentPickerViewController(forOpeningContentTypes: folderTypes, asCopy: false)
            picker.allowsMultipleSelection = false
        } else if type == .unified {
            // Matches the FolderPicker from 5556dd2 exactly:
            // asCopy:false + allowsMultipleSelection:false + .folder in types.
            // This is what causes iOS to show an active "Open" button when the
            // user is browsing inside a folder — without needing to select anything.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
            picker.allowsMultipleSelection = false
        } else {
            let asCopy = type == .files || type == .json || type == .smartList
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: asCopy)
            picker.allowsMultipleSelection = (type == .files)
        }
        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true

        Logger.shared.log("ImportCoordinator: Presenting \(type) picker", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }
        
        // iOS 17+ auto-dismisses UIDocumentPickerViewController after user selection.
        // On iOS 16, it does not. We call dismiss here for iOS 16 compatibility,
        // but do NOT gate processing on the completion block — it may never fire on iOS 17.
        controller.dismiss(animated: true, completion: nil)
        
        // Capture type before going to background
        let type = self.currentType
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            if type == .folder {
                var allFound: [URL] = []
                for url in urls {
                    let isAccessing = url.startAccessingSecurityScopedResource()
                    allFound.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                    if isAccessing { url.stopAccessingSecurityScopedResource() }
                }
                DispatchQueue.main.async { self.finish(with: allFound) }
            } else if type == .unified {
                var allFound: [URL] = []
                let fm = FileManager.default
                let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
                let stagingDir = fm.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
                try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                            for case let fileURL as URL in enumerator {
                                guard allowedExts.contains(fileURL.pathExtension.lowercased()) else { continue }
                                let dest = stagingDir.appendingPathComponent(fileURL.lastPathComponent)
                                do {
                                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                                    try fm.copyItem(at: fileURL, to: dest)
                                    allFound.append(dest)
                                } catch {
                                    Logger.shared.log("ImportCoordinator: Copy failed for \(fileURL.lastPathComponent): \(error)", category: "System", type: .warning)
                                }
                            }
                        }
                    } else if allowedExts.contains(url.pathExtension.lowercased()) {
                        let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
                        do {
                            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                            try fm.copyItem(at: url, to: dest)
                            allFound.append(dest)
                        } catch {
                            Logger.shared.log("ImportCoordinator: Single file copy failed for \(url.lastPathComponent): \(error)", category: "System", type: .warning)
                        }
                    }
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                DispatchQueue.main.async { self.finish(with: allFound) }
            } else {
                DispatchQueue.main.async {
                    self.finish(with: urls)
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Private Methods
    
    static func processFolderSpiderSync(url: URL) -> [URL] {
        var foundURLs: [URL] = []
        let validExts = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Folder_Spider_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if validExts.contains(fileURL.pathExtension.lowercased()) {
                    let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                        try fm.copyItem(at: fileURL, to: destURL)
                        foundURLs.append(destURL)
                    } catch {
                        Logger.shared.log("ImportCoordinator: Spider Copy Failed for \(fileURL.lastPathComponent): \(error)", category: "System", type: .warning)
                    }
                }
            }
        }
        
        return foundURLs
    }

    private func finish(with urls: [URL]) {
        completion?(urls)
        completion = nil
        ImportCoordinator.live = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let rootVC = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? windowScene?.windows.first?.rootViewController else { return nil }
        var top = rootVC
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
