import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS Folder picker with `asCopy: false` to establish
/// a live, linked connection to an external USB drive, Dropbox, iCloud Drive,
/// Google Drive, or any other Files-app provider — without copying files to the sandbox.
@MainActor
final class FolderLinkCoordinator: NSObject, UIDocumentPickerDelegate {

    private static var live: FolderLinkCoordinator?
    /// Called with every picked URL and bookmark. Passes an empty array on cancel.
    private var completion: (@MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void)?

    private override init() {}

    /// Present the folder picker.
    /// - Parameter completion: Receives all selected folder URLs and bookmark data, or an empty array on cancel.
    static func present(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        guard let rootVC = topViewController() else {
            Logger.shared.log("FolderLinkCoordinator: no root view controller found — cannot present picker", category: "FolderLink", type: .error)
            completion([])
            FolderLinkCoordinator.live = nil
            return
        }

        var supportedTypes: [UTType] = [.folder, .directory, .pdf, .epub]
        if let cbz = UTType(filenameExtension: "cbz") { supportedTypes.append(cbz) }
        if let cbr = UTType(filenameExtension: "cbr") { supportedTypes.append(cbr) }
        if let cb7 = UTType(filenameExtension: "cb7") { supportedTypes.append(cb7) }
        if let cbt = UTType(filenameExtension: "cbt") { supportedTypes.append(cbt) }
        if let zip = UTType(filenameExtension: "zip") { supportedTypes.append(zip) }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .pageSheet

        Logger.shared.log("FolderLinkCoordinator: presenting folder and file picker", category: "FolderLink", type: .info)
        rootVC.present(picker, animated: true)
    }

    /// Present the document picker allowing users to link specific comic/book files directly without copying.
    /// - Parameter completion: Receives all selected file URLs and bookmark data, or empty array on cancel.
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

        var supportedTypes: [UTType] = [.pdf, .epub]
        if let cbz = UTType(filenameExtension: "cbz") { supportedTypes.append(cbz) }
        if let cbr = UTType(filenameExtension: "cbr") { supportedTypes.append(cbr) }
        if let cb7 = UTType(filenameExtension: "cb7") { supportedTypes.append(cb7) }
        if let cbt = UTType(filenameExtension: "cbt") { supportedTypes.append(cbt) }
        if let zip = UTType(filenameExtension: "zip") { supportedTypes.append(zip) }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .pageSheet

        Logger.shared.log("FolderLinkCoordinator: presenting direct file picker for linked files", category: "FolderLink", type: .info)
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Legacy single-URL callback — bridge to the multi-URL handler.
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
        
        // Synchronously capture security scopes on main thread BEFORE dismissal or async dispatch
        var securedURLs: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                securedURLs.append(url)
            }
        }

        // Dismiss picker immediately so host UI is never blocked or frozen
        controller.dismiss(animated: true)

        // Offload bookmark creation to background task while scopes are held active
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                for url in securedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            var results: [(url: URL, bookmark: Data)] = []
            results.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                if index % 25 == 0 { await Task.yield() }
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
                    results.append((url, bookmarkData))
                }
            }
            await MainActor.run {
                self?.finish(with: results)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("FolderLinkCoordinator: user cancelled folder picker", category: "FolderLink", type: .info)
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
        
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
