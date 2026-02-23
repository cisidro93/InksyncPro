import UIKit
import UniformTypeIdentifiers

/// A persistent coordinator that presents an iOS folder picker outside of SwiftUI's
/// broken `.fileImporter` / UIViewControllerRepresentable wrapper stack.
///
/// The iOS 16/17 bug: SwiftUI's `.fileImporter(allowedContentTypes: [.folder])` silently
/// drops the completion callback when its host view is embedded in a NavigationStack
/// or TabView — even at the root window level. This class bypasses SwiftUI entirely.
///
/// Retains itself until the picker is dismissed to prevent premature deallocation.
final class FolderImportCoordinator: NSObject, UIDocumentPickerDelegate {

    // Strong reference kept alive for the duration of picker presentation
    private static var live: FolderImportCoordinator?

    private var completion: ((URL?) -> Void)?

    private override init() {}

    /// Present the folder picker from the top-most view controller in the active window scene.
    /// - Parameter completion: Called with the selected folder URL, or `nil` on cancel.
    static func present(completion: @escaping (URL?) -> Void) {
        // Retain the coordinator so it isn't deallocated before the delegate fires
        let coordinator = FolderImportCoordinator()
        coordinator.completion = completion
        FolderImportCoordinator.live = coordinator

        guard let rootVC = FolderImportCoordinator.topViewController() else {
            Logger.shared.log("FolderImportCoordinator: Could not find a root view controller.", category: "System")
            completion(nil)
            FolderImportCoordinator.live = nil
            return
        }

        // Use ONLY .folder — mixing .folder + .directory causes a callback-drop bug on iOS 16/17
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true

        Logger.shared.log("FolderImportCoordinator: Presenting picker on \(type(of: rootVC)).", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Logger.shared.log("FolderImportCoordinator: didPickDocumentsAt — \(urls.count) item(s).", category: "System")
        guard let url = urls.first else {
            Logger.shared.log("FolderImportCoordinator: Empty URL array returned.", category: "System")
            finish(with: nil)
            return
        }
        Logger.shared.log("FolderImportCoordinator: Selected folder → \(url.lastPathComponent)", category: "System")
        finish(with: url)
    }

    // Legacy delegate (iOS 14 fallback path still triggered on some iOS 17 builds)
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        Logger.shared.log("FolderImportCoordinator: didPickDocumentAt (legacy) — \(url.lastPathComponent)", category: "System")
        finish(with: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("FolderImportCoordinator: Picker cancelled by user.", category: "System")
        finish(with: nil)
    }

    // MARK: - Private

    private func finish(with url: URL?) {
        completion?(url)
        completion = nil
        // Release the strong self-reference after the delegate fires
        FolderImportCoordinator.live = nil
    }

    /// Walk the presented view controller chain to find the topmost one.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let rootVC = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? windowScene?.windows.first?.rootViewController else { return nil }
        var top = rootVC
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
