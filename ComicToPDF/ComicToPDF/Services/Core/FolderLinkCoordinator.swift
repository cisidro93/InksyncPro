import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS Folder or File picker with `asCopy: false` to establish
/// a live, linked connection to an external USB drive, Dropbox, iCloud Drive,
/// Google Drive, or any other Files-app provider — without copying files to the sandbox.
@MainActor
final class FolderLinkCoordinator: NSObject, UIDocumentPickerDelegate {

    private static var live: FolderLinkCoordinator?
    /// Called with every picked URL and bookmark. Passes an empty array on cancel.
    private var completion: (@MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void)?

    private override init() {}

    /// Comprehensive UTTypes matching all supported comic, book, and archive types across
    /// APFS, HFS+, FAT32, exFAT, and external USB storage volumes.
    static var supportedFileTypes: [UTType] {
        var types: [UTType] = [.pdf, .epub, .zip, .archive, .data]
        if let cbz = UTType(filenameExtension: "cbz") { types.append(cbz) }
        if let cbr = UTType(filenameExtension: "cbr") { types.append(cbr) }
        if let cb7 = UTType(filenameExtension: "cb7") { types.append(cb7) }
        if let cbt = UTType(filenameExtension: "cbt") { types.append(cbt) }
        if let rar = UTType(filenameExtension: "rar") { types.append(rar) }
        if let cbzCustom = UTType("com.antigravity.cbz") { types.append(cbzCustom) }
        if let cbrCustom = UTType("com.antigravity.cbr") { types.append(cbrCustom) }
        if let comicZip = UTType("com.macrabbit.comicbookzip") { types.append(comicZip) }
        if let comicRar = UTType("com.macrabbit.comicbookrar") { types.append(comicRar) }
        return types
    }

    /// Present the folder picker for external USB drives or directory trees.
    /// In iPadOS, allowsMultipleSelection MUST be false and types MUST only include folders,
    /// enabling the top-right "Open" button to immediately choose the directory without spinning.
    static func presentFolder(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        guard let rootVC = topViewController() else {
            Logger.shared.log("FolderLinkCoordinator: no root view controller found — cannot present folder picker", category: "FolderLink", type: .error)
            completion([])
            FolderLinkCoordinator.live = nil
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .directory], asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            picker.modalPresentationStyle = .formSheet
        } else {
            picker.modalPresentationStyle = .fullScreen
        }

        Logger.shared.log("FolderLinkCoordinator: presenting dedicated folder picker", category: "FolderLink", type: .info)
        rootVC.present(picker, animated: true)
    }

    /// Backward-compatible alias for folder linking.
    static func present(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        presentFolder(completion: completion)
    }

    /// Present the document picker allowing users to link specific comic/book files directly without copying.
    /// Supports multi-selection and includes fallback base UTIs for external FAT32/exFAT drives.
    static func presentFiles(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        guard let rootVC = topViewController() else {
            Logger.shared.log("FolderLinkCoordinator: no root view controller found — cannot present file picker", category: "FolderLink", type: .error)
            completion([])
            FolderLinkCoordinator.live = nil
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedFileTypes, asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            picker.modalPresentationStyle = .formSheet
        } else {
            picker.modalPresentationStyle = .fullScreen
        }

        Logger.shared.log("FolderLinkCoordinator: presenting direct multi-file picker for linked files", category: "FolderLink", type: .info)
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Single-URL callback required by iPadOS when allowsMultipleSelection = false and a folder is picked.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            controller.dismiss(animated: true)
            finish(with: [])
            return
        }
        Logger.shared.log("FolderLinkCoordinator: user picked \(urls.count) item(s): \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", category: "FolderLink", type: .success)

        // Dismiss picker immediately first — prevents XPC deadlocks with remote file provider
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }

            // Offload security scoping and bookmark creation to background task
            Task.detached(priority: .userInitiated) { [weak self] in
                var results: [(url: URL, bookmark: Data)] = []
                results.reserveCapacity(urls.count)

                for (index, url) in urls.enumerated() {
                    if index % 25 == 0 { await Task.yield() }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    var bookmarkData: Data? = try? url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    if bookmarkData == nil {
                        bookmarkData = try? url.bookmarkData(
                            options: .minimalBookmark,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                    }
                    if bookmarkData == nil {
                        bookmarkData = try? NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: true)
                    }

                    if let bookmarkData {
                        var isStale = false
                        let resolvedURL = (try? URL(
                            resolvingBookmarkData: bookmarkData,
                            options: .withoutUI,
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale
                        )) ?? url
                        results.append((resolvedURL, bookmarkData))
                    }
                }

                await MainActor.run {
                    self?.finish(with: results)
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("FolderLinkCoordinator: user cancelled picker", category: "FolderLink", type: .info)
        controller.dismiss(animated: true)
        finish(with: [])
    }

    // MARK: - Private

    private func finish(with results: [(url: URL, bookmark: Data)]) {
        completion?(results)
        completion = nil
        FolderLinkCoordinator.live = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        var windowScene: UIWindowScene? = nil
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            windowScene = active
        } else if let first = scenes.first as? UIWindowScene {
            windowScene = first
        }
        guard let windowScene = windowScene else { return nil }
        
        var root: UIViewController? = nil
        if let keyRoot = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            root = keyRoot
        } else if let firstRoot = windowScene.windows.first?.rootViewController {
            root = firstRoot
        }
        guard var top = root else { return nil }
        
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
