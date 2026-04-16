import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS Folder picker with `asCopy: false` to establish
/// a live, linked connection to an external USB drive or network share.
final class FolderLinkCoordinator: NSObject, UIDocumentPickerDelegate {

    private static var live: FolderLinkCoordinator?
    private var completion: ((URL?) -> Void)?

    private override init() {}

    /// Present the folder picker to link an external drive.
    static func present(completion: @escaping (URL?) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        guard let rootVC = topViewController() else {
            completion(nil)
            FolderLinkCoordinator.live = nil
            return
        }

        // asCopy: false is CRITICAL. It prevents iOS from freezing the UI to copy a 100GB
        // hard drive into the application sandbox before returning.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        // iPads notoriously swallow UIDocumentPickerViewController UI events if it's 
        // presented as a formSheet over an existing Settings formSheet.
        picker.modalPresentationStyle = .fullScreen 
        
        rootVC.present(picker, animated: true)
    }

    /// iOS fundamentally requires this deprecated delegate method when allowsMultipleSelection = false 
    /// and the picker is targeting `.folder`, otherwise the "Open" button simply does nothing.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedURL = urls.first else {
            finish(with: nil)
            return
        }
        
        // Dismiss first so processing isn't blocked on animation
        controller.dismiss(animated: true)
        
        // Do NOT start/stop security access here.
        // The system grants us a temporary window after didPickDocuments fires.
        // LinkedLibraryScanner.linkDrive() starts its own security scope independently
        // using the bookmark it creates from this URL. Starting it here and passing
        // the URL into an async closure would race the defer-based stop call.
        finish(with: selectedURL)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(with: nil)
    }

    private func finish(with url: URL?) {
        completion?(url)
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
