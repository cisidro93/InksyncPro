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
        default:
            // Unified Legacy Forward-Port (0bb6b38)
            supportedTypes = [
                .pdf, .zip, .folder, .archive,
                UTType(filenameExtension: "epub") ?? .epub,
                UTType(filenameExtension: "cbz") ?? .zip,
                UTType(filenameExtension: "cbr") ?? .archive,
                UTType(filenameExtension: "cb7") ?? .archive
            ].compactMap { $0 }
        }

        let picker: UIDocumentPickerViewController

        if type == .json || type == .smartList {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
            picker.allowsMultipleSelection = false
        } else {
            // Legacy 0bb6b38 Perfection: Unified Picker handles BOTH files and folders simultaneously natively.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
            picker.allowsMultipleSelection = true
        }

        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .fullScreen
        Logger.shared.log("ImportCoordinator: Presenting structured picker payload natively.", category: "System")
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

        // Dismiss the picker immediately — asCopy:false never auto-dismisses.
        // We do NOT use a completion block so processing is not gated on the animation.
        controller.dismiss(animated: true)
        
        // Process on background queue in parallel with the dismiss animation.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if self.currentType == .json || self.currentType == .smartList {
                DispatchQueue.main.async { self.finish(with: urls) }
                return
            }

            // --- 0bb6b38 Legacy extraction block + SeriesNameParser staging ---
            let fm = FileManager.default
            let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
            
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
            try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            
            var foundURLs: [URL] = []

            for url in urls {
                let secured = url.startAccessingSecurityScopedResource()
                
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    // Recursively spider the directory synchronously
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                        for case let fileURL as URL in enumerator {
                            if allowedExts.contains(fileURL.pathExtension.lowercased()) {
                                // Preserve native structure for SeriesNameParser Context
                                let originalParent = fileURL.deletingLastPathComponent().lastPathComponent
                                let destFolder = stagingDir.appendingPathComponent(originalParent)
                                try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                                
                                let destURL = destFolder.appendingPathComponent(fileURL.lastPathComponent)
                                do {
                                    if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                                    try fm.copyItem(at: fileURL, to: destURL)
                                    foundURLs.append(destURL)
                                } catch {
                                    Logger.shared.log("ImportCoordinator: Copy failed \(fileURL.lastPathComponent)", category: "System", type: .warning)
                                }
                            }
                        }
                    }
                } else {
                    // It's a standard single file selection
                    if allowedExts.contains(url.pathExtension.lowercased()) {
                        let originalParent = url.deletingLastPathComponent().lastPathComponent
                        let destFolder = stagingDir.appendingPathComponent(originalParent)
                        try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                        
                        let destURL = destFolder.appendingPathComponent(url.lastPathComponent)
                        do {
                            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                            try fm.copyItem(at: url, to: destURL)
                            foundURLs.append(destURL)
                        } catch {
                            Logger.shared.log("ImportCoordinator: Copy failed \(url.lastPathComponent)", category: "System", type: .warning)
                        }
                    }
                }
                
                if secured {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            DispatchQueue.main.async { self.finish(with: foundURLs) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Helpers



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
