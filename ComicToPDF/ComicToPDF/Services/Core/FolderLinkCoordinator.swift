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
        
        // Immediately dismiss so processing doesn't block the UI
        controller.dismiss(animated: true)
        
        // The URL returned has a temporary security scope granted by the DocumentPicker.
        // We MUST start accessing it immediately to generate the persistent bookmark data.
        let accessing = selectedURL.startAccessingSecurityScopedResource()
        defer { if accessing { selectedURL.stopAccessingSecurityScopedResource() } }
        
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
