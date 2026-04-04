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
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .directory], asCopy: false)
            picker.allowsMultipleSelection = false

        } else if type == .unified {
            // ─── Critical Design ───────────────────────────────────────────────────
            // asCopy: false   → security-scoped URLs; we copy files manually inside the scope.
            // allowsMultipleSelection: false → iOS shows an active "Open" button when the
            //   user is navigated INSIDE a folder. With `true`, tapping a folder navigates
            //   into it, breaking the "open this whole folder" use case the user expects.
            // .folder in contentTypes → delivers the folder URL when user hits Open.
            //
            // Flow: user browses to Downloads/en.mangafox → hits Open → we spider that folder.
            // ───────────────────────────────────────────────────────────────────────
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
            picker.allowsMultipleSelection = false

        } else {
            let asCopy = (type == .files || type == .json || type == .smartList)
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: asCopy)
            picker.allowsMultipleSelection = (type == .files)
        }

        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        Logger.shared.log("ImportCoordinator: Presenting \(type) picker.", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }

        // CRITICAL: With asCopy:false, iOS 17+ auto-dismisses the picker BEFORE calling this
        // delegate. Calling controller.dismiss() again produces a completion block that never
        // fires on those OS versions, silently dropping the entire import.
        // Solution: process URLs directly on a background queue — no dismiss call needed.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            switch self.currentType {

            case .folder:
                var found: [URL] = []
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    found.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                DispatchQueue.main.async { self.finish(with: found) }

            case .unified:
                let fm = FileManager.default
                let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
                let stagingDir = fm.temporaryDirectory
                    .appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
                try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                var found: [URL] = []

                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

                    if isDir.boolValue {
                        fm.enumerator(at: url,
                                      includingPropertiesForKeys: [.isDirectoryKey],
                                      options: [.skipsHiddenFiles])?
                            .forEach { item in
                                guard let fileURL = item as? URL,
                                      allowedExts.contains(fileURL.pathExtension.lowercased()) else { return }
                                let dest = stagingDir.appendingPathComponent(fileURL.lastPathComponent)
                                do {
                                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                                    try fm.copyItem(at: fileURL, to: dest)
                                    found.append(dest)
                                } catch {
                                    Logger.shared.log("ImportCoordinator: Folder copy failed (\(fileURL.lastPathComponent)): \(error)", category: "System", type: .warning)
                                }
                            }
                    } else if allowedExts.contains(url.pathExtension.lowercased()) {
                        let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
                        do {
                            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                            try fm.copyItem(at: url, to: dest)
                            found.append(dest)
                        } catch {
                            Logger.shared.log("ImportCoordinator: File copy failed (\(url.lastPathComponent)): \(error)", category: "System", type: .warning)
                        }
                    }
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

    /// Synchronously spiders a folder and copies all valid comic files to temp storage.
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
                        Logger.shared.log("ImportCoordinator: Spider copy failed (\(fileURL.lastPathComponent)): \(error)", category: "System", type: .warning)
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
        guard let root = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                      ?? windowScene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
