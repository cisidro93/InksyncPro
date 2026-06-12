import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS Folder picker with `asCopy: false` to establish
/// a live, linked connection to an external USB drive, Dropbox, iCloud Drive,
/// Google Drive, or any other Files-app provider — without copying files to the sandbox.
final class FolderLinkCoordinator: NSObject, UIDocumentPickerDelegate {

    private static var live: FolderLinkCoordinator?
    /// Called with every picked URL. Passes an empty array on cancel.
    private var completion: (([URL]) -> Void)?

    private override init() {}

    /// Present the folder picker.
    /// - Parameter completion: Receives all selected folder URLs, or an empty array on cancel.
    static func present(completion: @escaping ([URL]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        guard let rootVC = topViewController() else {
            Logger.shared.log("FolderLinkCoordinator: no root view controller found — cannot present picker", category: "FolderLink", type: .error)
            completion([])
            FolderLinkCoordinator.live = nil
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .pageSheet

        Logger.shared.log("FolderLinkCoordinator: presenting folder picker", category: "FolderLink", type: .info)
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Legacy single-URL callback — bridge to the multi-URL handler.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }
        Logger.shared.log("FolderLinkCoordinator: user picked \(urls.count) folder(s): \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", category: "FolderLink", type: .success)
        controller.dismiss(animated: true)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.main.async {
                self?.finish(with: urls)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("FolderLinkCoordinator: user cancelled folder picker", category: "FolderLink", type: .info)
        finish(with: [])
    }

    // MARK: - Private

    private func finish(with urls: [URL]) {
        completion?(urls)
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
