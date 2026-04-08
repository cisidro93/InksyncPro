import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS File/Folder picker globally, completely bypassing SwiftUI `.sheet`
/// bugs that cause thread locks or frozen "Open" buttons.
final class ImportCoordinator: NSObject, UIDocumentPickerDelegate {

    enum ImportType {
        case files
        case folder
        case json       // For settings/exports
        case smartList  // For cbl, csv, md, txt
        case unified    // Universal hybrid file and folder picker
    }

    // Strong reference held so ARC doesn't collect the coordinator before the delegate fires.
    // Always replaced — never guarded — so stale references can never deadlock the UI.
    private static var live: ImportCoordinator?
    private var completion: (([URL]) -> Void)?
    private var currentType: ImportType = .files

    private override init() {}

    // MARK: - Present

    /// Present the file picker from the topmost active view controller.
    /// If a stale reference exists it is replaced immediately; taps are never silently dropped.
    static func present(type: ImportType = .files, completion: @escaping ([URL]) -> Void) {
        let coordinator = ImportCoordinator()
        coordinator.completion = completion
        coordinator.currentType = type
        ImportCoordinator.live = coordinator // always replace, never guard

        guard let rootVC = ImportCoordinator.topViewController() else {
            Logger.shared.log("ImportCoordinator: No root view controller found.", category: "System", type: .error)
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
            // asCopy:false → Open button stays ACTIVE while user is navigated inside a folder.
            // The delegate receives a security-scoped URL for the chosen folder.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .directory], asCopy: false)
            picker.allowsMultipleSelection = false
        } else if type == .unified {
            // Security scoped URLs manually handled to support recursive folder dumping AND file selecting
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
            picker.allowsMultipleSelection = true
        } else {
            let asCopy = (type == .files || type == .json || type == .smartList)
            // ✅ Fix iOS 16/17 UI Deadlock: `asCopy: true` forces a native copy before dismissing, bypassing `NSFileCoordinator` bugs.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: asCopy)
            picker.allowsMultipleSelection = (type == .files)
        }

        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        Logger.shared.log("ImportCoordinator: Presenting \(type) picker.", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Deprecated single-URL delegate (iOS < 11). iOS still calls THIS (not the multi-URL variant)
    /// when allowsMultipleSelection=false and a folder is selected via the .folder picker.
    /// The working binary explicitly implements this in FolderPickerV.Coordinator.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }

        // 1. MUST secure the URLs synchronously on the exact thread they are delivered to BEFORE the delegate returns!
        var securedURLs: [(URL, Bool)] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            securedURLs.append((url, accessing))
        }

        // DO NOT forcefully call `controller.dismiss(animated: true)`. Apple natively manages the File Picker UI dismissal. 
        // Manually dismissing it here conflicts with Apple's `isDismissing` state and permanently deadlocks the "Open" button spinner.

        // 3. Process on background queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            defer {
                // ALWAYS release kernel security locks when the background pipeline finishes
                for (url, accessing) in securedURLs {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            }

            switch self.currentType {
            case .folder:
                var found: [URL] = []
                for (url, _) in securedURLs {
                    found.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                }
                DispatchQueue.main.async { self.finish(with: found) }
                
            case .files:
                // .files returns standard OS-copied tmp URLs because `asCopy: true` was used! Safe to process.
                DispatchQueue.main.async { self.finish(with: urls) }

            case .unified:
                let fm = FileManager.default
                let allowedExts = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
                let stagingDir = fm.temporaryDirectory
                    .appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
                try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                var found: [URL] = []

                for (url, _) in securedURLs {
                    var isDirectory = false
                    if let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]), let isDir = resourceValues.isDirectory {
                        isDirectory = isDir
                    } else {
                        // Fallback heuristical check if resource keys fail on heavy dataless files
                        isDirectory = url.hasDirectoryPath
                    }
                    
                    if isDirectory {
                        found.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                    } else {
                        let ext = url.pathExtension.lowercased()
                        let isIcloud = (ext == "icloud")
                        let realExt = isIcloud ? (url.deletingPathExtension().pathExtension.lowercased()) : ext
                        
                        if allowedExts.contains(realExt) {
                            let finalName = isIcloud ? (url.deletingPathExtension().lastPathComponent) : url.lastPathComponent
                            let dest = stagingDir.appendingPathComponent(finalName)
                            
                            let fileCoordinator = NSFileCoordinator()
                            var copyError: NSError?
                            fileCoordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &copyError) { lockedFileURL in
                                do {
                                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                                    try fm.copyItem(at: lockedFileURL, to: dest)
                                    found.append(dest)
                                } catch {
                                    Logger.shared.log("ImportCoordinator: unified copy failed: \(error)", category: "System", type: .warning)
                                }
                            }
                            if let error = copyError {
                                Logger.shared.log("ImportCoordinator: unified staging failure: \(error)", category: "System", type: .warning)
                            }
                        }
                    }
                }
                DispatchQueue.main.async { self.finish(with: found) }

            default:
                // .files returns standard OS-copied tmp URLs because `asCopy: true` was used! Safe to process.
                DispatchQueue.main.async { self.finish(with: urls) }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Helpers

    /// Safely projects an NSFileCoordinator read-lock across a security-scoped Sandbox root and spiders recursively natively
    static func processFolderSpiderSync(url: URL) -> [URL] {
        var foundURLs: [URL] = []
        let validExts = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Folder_Spider_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let coordinator = NSFileCoordinator()
        var coordinateError: NSError?
        
        // Block explicitly synchrononizes read access for the entire Directory subtree natively bypassing iOS Sandbox limitations
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinateError) { secureURL in
            if let enumerator = fm.enumerator(at: secureURL, includingPropertiesForKeys: [.isDirectoryKey, .isUbiquitousItemKey], options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    // Extract true extension, bypassing .icloud shadows if any
                    let ext = fileURL.pathExtension.lowercased()
                    let isIcloud = (ext == "icloud")
                    let realExt = isIcloud ? (fileURL.deletingPathExtension().pathExtension.lowercased()) : ext
                    
                    if validExts.contains(realExt) {
                        let finalName = isIcloud ? (fileURL.deletingPathExtension().lastPathComponent) : fileURL.lastPathComponent
                        let destURL = tempDir.appendingPathComponent(finalName)
                        
                        do {
                            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                            
                            // To force iOS to hydrate shadow files or copy strict foreign-container files reliably, coordinate the SPECIFIC file individually.
                            let fileCoordinator = NSFileCoordinator()
                            var copyError: NSError?
                            fileCoordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &copyError) { lockedFileURL in
                                do {
                                    try fm.copyItem(at: lockedFileURL, to: destURL)
                                    foundURLs.append(destURL)
                                } catch {
                                    Logger.shared.log("ImportCoordinator: Sub-file Copy Failed (\(finalName)): \(error)", category: "System", type: .warning)
                                }
                            }
                        } catch {
                            Logger.shared.log("ImportCoordinator: Spider environment failed (\(finalName)): \(error)", category: "System", type: .warning)
                        }
                    }
                }
            } else {
                 Logger.shared.log("ImportCoordinator: Kernel refused enumeration inside active OS coordinator context.", category: "System", type: .error)
            }
        }
        
        if let error = coordinateError {
            Logger.shared.log("ImportCoordinator: Sandbox Coordinator failed to lock root url: \(error.localizedDescription)", category: "System", type: .error)
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
        guard let root = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                      ?? windowScene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
