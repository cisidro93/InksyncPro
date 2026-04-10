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
            // asCopy:true → The OS natively orchestrates copying and downloading the folder hierarchy securely into our tmp directory!
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .directory], asCopy: true)
            picker.allowsMultipleSelection = false
        } else if type == .unified {
            // ─── Critical Design ───────────────────────────────────────────────────
            // asCopy: false   → security-scoped URLs; we copy files manually inside the scope.
            // allowsMultipleSelection: true → allows the user to select multiple individual files 
            //   OR select a folder using the "Select" button. 
            //   If false, iOS breaks the "Open" button inside folders when mixing file and folder types.
            // ───────────────────────────────────────────────────────────────────────
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
            picker.allowsMultipleSelection = true
        } else {
            let asCopy = (type == .files || type == .json || type == .smartList)
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: asCopy)
            picker.allowsMultipleSelection = (type == .files)
        }

        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .fullScreen
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

        // Dismiss the picker immediately — asCopy:false never auto-dismisses.
        // We do NOT use a completion block so processing is not gated on the animation.
        controller.dismiss(animated: true)

        // Process on background queue in parallel with the dismiss animation.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            switch self.currentType {

            case .folder:
                // asCopy:true natively orchestrates folder copying/iCloud download into our Local Temp context!
                var found: [URL] = []
                for url in urls {
                    found.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                }
                DispatchQueue.main.async { self.finish(with: found) }

            case .unified, .files:
                let fm = FileManager.default
                let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
                let stagingDir = fm.temporaryDirectory
                    .appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
                try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                var found: [URL] = []

                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        // Folder — spider recursively safely via coordinator
                        found.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                    } else {
                        // File block
                        var targetURL = url
                        var actualExt = url.pathExtension.lowercased()
                        if actualExt == "icloud" {
                            let fileName = url.lastPathComponent
                            if fileName.hasPrefix(".") && fileName.hasSuffix(".icloud") {
                                let logicalName = String(fileName.dropFirst().dropLast(7))
                                actualExt = (logicalName as NSString).pathExtension.lowercased()
                                targetURL = url.deletingLastPathComponent().appendingPathComponent(logicalName)
                            }
                        }

                        if allowedExts.contains(actualExt) {
                            // PRESERVE the original parent folder context so `SeriesNameParser` groups files smartly!
                            let originalParent = targetURL.deletingLastPathComponent().lastPathComponent
                            let destFolder = stagingDir.appendingPathComponent(originalParent)
                            try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                            
                            let dest = destFolder.appendingPathComponent(targetURL.lastPathComponent)
                            if ImportCoordinator.secureCopy(from: targetURL, to: dest) {
                                found.append(dest)
                            } else {
                                Logger.shared.log("ImportCoordinator[files_copy]: coordinated copy failed (\(targetURL.lastPathComponent))", category: "System", type: .warning)
                            }
                        }
                    }
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                DispatchQueue.main.async { self.finish(with: found) }

            default:
                DispatchQueue.main.async { self.finish(with: urls) }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Helpers

    /// Fast, unblocked file spider for perfectly localized paths extracted via asCopy: true.
    static func processFolderSpiderSync(url: URL) -> [URL] {
        var foundURLs: [URL] = []
        let validExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let timeoutDate = Date().addingTimeInterval(30.0)

        // Native native traversal. No Security Scopes or NSFileCoordinator needed natively.
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if Date() > timeoutDate {
                    Logger.shared.log("ImportCoordinator: Folder spider timed out after 30 seconds", category: "System", type: .warning)
                    break
                }

                if validExts.contains(fileURL.pathExtension.lowercased()) {
                    let originalParent = fileURL.deletingLastPathComponent().lastPathComponent
                    let destFolder = stagingDir.appendingPathComponent(originalParent)
                    try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

                    let destURL = destFolder.appendingPathComponent(fileURL.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                        try fm.copyItem(at: fileURL, to: destURL)
                        foundURLs.append(destURL)
                    } catch {
                        Logger.shared.log("ImportCoordinator: Local fast-copy failed: \(error.localizedDescription)", category: "System", type: .error)
                    }
                }
            }
        }
        return foundURLs
    }
    
    /// Safely copies a file using NSFileCoordinator with empty options to trigger on-demand iCloud downloads and bypass security scopes.
    private static func secureCopy(from sourceURL: URL, to destURL: URL) -> Bool {
        var success = false
        var error: NSError?
        // options: [] deliberately forces iOS to materialize the iCloud dataless fault.
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &error) { safeURL in
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: safeURL, to: destURL)
                success = true
            } catch {
                Logger.shared.log("ImportCoordinator: Secure copy failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)", category: "System", type: .error)
            }
        }
        return success
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
