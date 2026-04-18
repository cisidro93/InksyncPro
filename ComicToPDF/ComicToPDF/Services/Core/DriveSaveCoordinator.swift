import UIKit
import UniformTypeIdentifiers

/// Presents a folder-picker so the user can choose (or create) a destination
/// folder on an external drive to save files into.
///
/// The user can navigate into any folder, including creating new folders via
/// the "New Folder" button that the native Files picker exposes automatically.
final class DriveSaveCoordinator: NSObject, UIDocumentPickerDelegate {

    private static var live: DriveSaveCoordinator?
    private var completion: ((URL?) -> Void)?

    private override init() {}

    /// Present the destination folder picker.
    /// - Parameter completion: Called with the chosen folder URL, or `nil` if cancelled.
    static func present(completion: @escaping (URL?) -> Void) {
        let coordinator = DriveSaveCoordinator()
        coordinator.completion = completion
        DriveSaveCoordinator.live = coordinator

        guard let rootVC = topViewController() else {
            completion(nil)
            DriveSaveCoordinator.live = nil
            return
        }

        // forOpeningContentTypes: [.folder] with asCopy: false gives the user
        // a live, security-scoped reference to the chosen folder.
        // The native picker automatically shows a "New Folder" button so users
        // can create new folders on the drive without leaving the app.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .fullScreen

        rootVC.present(picker, animated: true)
    }

    // Required for single-selection folder pickers on iOS
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedURL = urls.first else {
            finish(with: nil)
            return
        }

        // Start security scope here so it's live during the dismiss animation
        let accessing = selectedURL.startAccessingSecurityScopedResource()

        controller.dismiss(animated: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                if accessing { selectedURL.stopAccessingSecurityScopedResource() }
                return
            }
            DispatchQueue.main.async {
                self.finish(with: selectedURL)
                // saveFilesToDrive starts its own scope inside; safe to relinquish ours
                if accessing { selectedURL.stopAccessingSecurityScopedResource() }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(with: nil)
    }

    private func finish(with url: URL?) {
        completion?(url)
        completion = nil
        DriveSaveCoordinator.live = nil
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
