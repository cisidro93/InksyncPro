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
            completion([])
            FolderLinkCoordinator.live = nil
            return
        }

        // asCopy: false is CRITICAL — prevents iOS from silently downloading and copying
        // the entire cloud folder (Dropbox, iCloud, etc.) into the app sandbox.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        // Full-screen prevents iPadOS from swallowing events when presented over a form sheet.
        picker.modalPresentationStyle = .fullScreen

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

        // ⚠️ SECURITY SCOPE OWNERSHIP:
        // Start access on ALL picked URLs while still inside the delegate callback
        // where the grant is guaranteed to be live.
        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }

        controller.dismiss(animated: true)

        DispatchQueue.main.async { [weak self] in
            self?.finish(with: urls)
            // linkDrive() immediately re-acquires its own scope; release ours.
            accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
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
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let root = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                      ?? windowScene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
