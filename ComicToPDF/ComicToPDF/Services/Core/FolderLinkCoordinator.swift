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

    private var didFinishHandling = false

    /// Comprehensive UTTypes matching all supported comic, book, and archive types across
    /// APFS, HFS+, FAT32, exFAT, and external USB storage volumes.
    static var supportedFileTypes: [UTType] {
        var types: [UTType] = [.folder, .directory]
        if let vol = UTType("public.volume") { types.append(vol) }
        types.append(contentsOf: [.pdf, .epub, .zip, .archive, .data])
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

    /// Dedicated folder and external volume UTTypes for folder picking.
    /// Includes public.volume so root of external USB drives is never greyed out on iPadOS.
    static var supportedFolderTypes: [UTType] {
        var types: [UTType] = [.folder, .directory]
        if let vol = UTType("public.volume") { types.append(vol) }
        if let item = UTType("public.item") { types.append(item) }
        return types
    }

    /// Present the folder picker for external USB drives or directory trees.
    static func presentFolder(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedFolderTypes, asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            picker.modalPresentationStyle = .formSheet
        } else {
            picker.modalPresentationStyle = .fullScreen
        }

        Logger.shared.log("FolderLinkCoordinator: presenting dedicated folder picker", category: "FolderLink", type: .info)
        presentSafely(picker)
    }

    /// Unified presentation for external drives: allows picking folders, the drive root, or comic files directly.
    static func present(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedFileTypes, asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            picker.modalPresentationStyle = .formSheet
        } else {
            picker.modalPresentationStyle = .fullScreen
        }

        Logger.shared.log("FolderLinkCoordinator: presenting unified drive picker", category: "FolderLink", type: .info)
        presentSafely(picker)
    }

    /// Present the document picker allowing users to link specific comic/book files directly without copying.
    /// Supports multi-selection and includes fallback base UTIs for external FAT32/exFAT drives.
    static func presentFiles(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

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
        presentSafely(picker)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Single-URL callback required by iPadOS when allowsMultipleSelection = false and a folder is picked.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        handlePickedURLs([url], from: controller)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        handlePickedURLs(urls, from: controller)
    }

    private func handlePickedURLs(_ urls: [URL], from controller: UIDocumentPickerViewController) {
        guard !didFinishHandling else { return }
        didFinishHandling = true

        guard !urls.isEmpty else {
            if controller.isBeingDismissed || controller.presentingViewController == nil {
                finish(with: [])
            } else {
                controller.dismiss(animated: true) { [weak self] in
                    self?.finish(with: [])
                }
            }
            return
        }
        Logger.shared.log("FolderLinkCoordinator: user picked \(urls.count) item(s): \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", category: "FolderLink", type: .success)

        // Capture security-scoped bookmarks SYNCHRONOUSLY while the system picker's temporary
        // sandbox extension is 100% active and before dismissal can invalidate the kernel token.
        var results: [(url: URL, bookmark: Data)] = []
        results.reserveCapacity(urls.count)

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var bookmarkData: Data? = nil
            do {
                bookmarkData = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                Logger.shared.log("FolderLinkCoordinator: Standard bookmark failed for \(url.lastPathComponent): \(error.localizedDescription) — trying .minimalBookmark", category: "FolderLink", type: .warning)
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
            } else {
                Logger.shared.log("FolderLinkCoordinator: Failed to create bookmark for \(url.lastPathComponent)", category: "FolderLink", type: .error)
            }
        }

        let capturedResults = results
        if controller.isBeingDismissed || controller.presentingViewController == nil {
            self.finish(with: capturedResults)
        } else {
            controller.dismiss(animated: true) { [weak self] in
                self?.finish(with: capturedResults)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !didFinishHandling else { return }
        didFinishHandling = true
        Logger.shared.log("FolderLinkCoordinator: user cancelled picker", category: "FolderLink", type: .info)
        if controller.isBeingDismissed || controller.presentingViewController == nil {
            finish(with: [])
        } else {
            controller.dismiss(animated: true) { [weak self] in
                self?.finish(with: [])
            }
        }
    }

    // MARK: - Private

    private func finish(with results: [(url: URL, bookmark: Data)]) {
        completion?(results)
        completion = nil
        FolderLinkCoordinator.live = nil
    }

    private static func presentSafely(_ picker: UIViewController) {
        guard let rootVC = topViewController() else {
            Logger.shared.log("FolderLinkCoordinator: no root view controller found — cannot present picker", category: "FolderLink", type: .error)
            live?.finish(with: [])
            return
        }

        if let presented = rootVC.presentedViewController {
            if presented.isBeingDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if let safeTop = topViewController() {
                        safeTop.present(picker, animated: true)
                    } else {
                        live?.finish(with: [])
                    }
                }
                return
            } else {
                presented.present(picker, animated: true)
                return
            }
        }
        rootVC.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }

        let candidateWindows = windowScene.windows.filter { window in
            let desc = String(describing: type(of: window))
            return !desc.contains("UITextEffectsWindow") && !desc.contains("UIRemoteKeyboardWindow")
        }
        let keyWindow = candidateWindows.first(where: { $0.isKeyWindow }) ?? candidateWindows.first ?? windowScene.windows.first
        guard var top = keyWindow?.rootViewController else { return nil }
        
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
