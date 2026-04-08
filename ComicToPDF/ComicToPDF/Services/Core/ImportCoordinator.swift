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

        // Dismiss the picker — asCopy:false never auto-dismisses.
        // Processing starts in the completion block AFTER dismiss finishes.
        // This matches the proven 697adbe pattern that is running on the user's phone.
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                switch self.currentType {

                case .folder:
                    var allFound: [URL] = []
                    for url in urls {
                        let isAccessing = url.startAccessingSecurityScopedResource()
                        allFound.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                        if isAccessing { url.stopAccessingSecurityScopedResource() }
                    }
                    DispatchQueue.main.async { self.finish(with: allFound) }

                case .unified:
                    // asCopy:false means we hold the security scope and must copy files
                    // to our own staging dir before releasing it.
                    var allFound: [URL] = []
                    let fm = FileManager.default
                    let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
                    let stagingDir = fm.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
                    try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            // Folder opened — recursively copy all valid files while scope is active
                            allFound.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                        } else if allowedExts.contains(url.pathExtension.lowercased()) {
                            // Single file — copy to staging
                            let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
                            do {
                                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                                try fm.copyItem(at: url, to: dest)
                                allFound.append(dest)
                            } catch {
                                Logger.shared.log("ImportCoordinator[unified/file]: copy failed (\(url.lastPathComponent)): \(error.localizedDescription)", category: "System", type: .warning)
                            }
                        }
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    DispatchQueue.main.async { self.finish(with: allFound) }

                default:
                    // .files returns standard OS-copied tmp URLs because `asCopy: true` was used.
                    DispatchQueue.main.async { self.finish(with: urls) }
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Helpers

    /// Synchronously spiders a folder and copies all valid comic files to temp storage.
    /// Uses NSFileCoordinator to project read-locks across "On My iPad" sandbox boundaries.
    static func processFolderSpiderSync(url: URL) -> [URL] {
        var foundURLs: [URL] = []
        let validExts = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Folder_Spider_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Wrap enumeration in NSFileCoordinator to gain kernel-level read access
        // for directories outside our sandbox (e.g. "On My iPad" local storage).
        var coordError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordError
        ) { coordURL in
            guard let enumerator = fm.enumerator(
                at: coordURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let fileURL as URL in enumerator {
                if validExts.contains(fileURL.pathExtension.lowercased()) {
                    let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                        try fm.copyItem(at: fileURL, to: destURL)
                        foundURLs.append(destURL)
                    } catch {
                        Logger.shared.log("ImportCoordinator: Spider copy failed (\(fileURL.lastPathComponent)): \(error)", category: "System", type: .warning)
                    }
                }
            }
        }
        if let e = coordError {
            Logger.shared.log("ImportCoordinator: Folder coordinator error: \(e.localizedDescription)", category: "System", type: .error)
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
