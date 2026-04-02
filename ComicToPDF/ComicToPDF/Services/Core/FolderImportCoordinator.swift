import UIKit
import UniformTypeIdentifiers

/// Presents a multi-file picker that lets the user select CBZ/EPUB files from
/// ANY location — including third-party app sandboxes like Aidoku — and returns them
/// as copies that InksyncPro owns.
///
/// Background: iOS sandboxing prevents folder-level security-scoped access to another
/// app's container. However, individual FILE copies are always permitted. We use this
/// to simulate "Import Folder": the user navigates to the folder and selects all the
/// files they want. InksyncPro then infers the series name from the common parent
/// directory, preserving automatic collection grouping.
final class FolderImportCoordinator: NSObject, UIDocumentPickerDelegate {

    // Strong self-retention: prevents ARC from deallocating before delegate fires
    private static var live: FolderImportCoordinator?

    private var completion: (([URL]) -> Void)?

    private override init() {}

    /// Present the multi-file picker from the topmost active view controller.
    /// - Parameter completion: Returns the list of copied file URLs, or empty on cancel.
    static func present(completion: @escaping ([URL]) -> Void) {
        let coordinator = FolderImportCoordinator()
        coordinator.completion = completion
        FolderImportCoordinator.live = coordinator

        guard let rootVC = FolderImportCoordinator.topViewController() else {
            Logger.shared.log("FolderImportCoordinator: Could not find root view controller.", category: "System")
            completion([])
            FolderImportCoordinator.live = nil
            return
        }

        let supportedTypes: [UTType] = [
            UTType(filenameExtension: "cbz") ?? .zip,

            UTType(filenameExtension: "cb7") ?? .archive,
            .epub,
            .zip,
            .archive
        ]

        // asCopy: true is required to access files in third-party app sandboxes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true

        Logger.shared.log("FolderImportCoordinator: Presenting multi-file picker on \(type(of: rootVC)).", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Logger.shared.log("FolderImportCoordinator: didPickDocumentsAt — \(urls.count) file(s) selected.", category: "System")
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }
        controller.dismiss(animated: true) {
            self.finish(with: urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("FolderImportCoordinator: Picker cancelled.", category: "System")
        finish(with: [])
    }

    // MARK: - Private

    private func finish(with urls: [URL]) {
        completion?(urls)
        completion = nil
        FolderImportCoordinator.live = nil
    }

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
