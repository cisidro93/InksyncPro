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

    /// Clean, explicit comic/book UTTypes.
    /// CRITICAL: Contains ONLY concrete file types.
    /// NEVER include .folder, .directory, public.volume, public.item, or .data here.
    static var supportedFileTypes: [UTType] {
        var types: [UTType] = [
            .pdf,
            .zip,
            UTType(filenameExtension: "epub") ?? .epub,
            UTType(filenameExtension: "cbz") ?? .zip,
            UTType(filenameExtension: "cbr") ?? .archive,
            UTType(filenameExtension: "cb7") ?? .archive,
            UTType(filenameExtension: "cbt") ?? .archive,
            UTType(filenameExtension: "rar") ?? .archive,
            UTType(filenameExtension: "7z") ?? .archive
        ]
        if let cbzCustom = UTType("com.antigravity.cbz") { types.append(cbzCustom) }
        if let cbrCustom = UTType("com.antigravity.cbr") { types.append(cbrCustom) }
        if let comicZip = UTType("com.macrabbit.comicbookzip") { types.append(comicZip) }
        if let comicRar = UTType("com.macrabbit.comicbookrar") { types.append(comicRar) }
        if let sevenZip = UTType("org.7-zip.7-zip-archive") { types.append(sevenZip) }
        return types.compactMap { $0 }
    }

    /// Dedicated folder UTTypes for folder picking.
    /// CRITICAL: Only `.folder` with `asCopy: false` and `allowsMultipleSelection: false`.
    /// In iOS/iPadOS, adding `public.item` or `public.volume` causes fileproviderd deadlock
    /// and indefinite spinning of the top-right "Open" button.
    static var supportedFolderTypes: [UTType] {
        return [.folder]
    }

    /// Present the folder picker for external USB drives or directory trees.
    /// Guarantees immediate "Open" response with zero spinning on iPadOS.
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

        Logger.shared.log("FolderLinkCoordinator: presenting dedicated folder picker (allowsMultipleSelection: false)", category: "FolderLink", type: .info)
        presentSafely(picker)
    }

    /// Present the multi-file document picker for linking specific comic/book files directly without copying.
    /// Supports multi-selection checkmarks and creates persistent bookmarks for each.
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

    /// Present the single-file document picker for instant streaming/reading without copying.
    /// allowsMultipleSelection = false: single tap selects and opens immediately.
    static func presentSingleFile(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        let coordinator = FolderLinkCoordinator()
        coordinator.completion = completion
        FolderLinkCoordinator.live = coordinator

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedFileTypes, asCopy: false)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            picker.modalPresentationStyle = .formSheet
        } else {
            picker.modalPresentationStyle = .fullScreen
        }

        Logger.shared.log("FolderLinkCoordinator: presenting direct single-file picker for instant streaming", category: "FolderLink", type: .info)
        presentSafely(picker)
    }

    /// Legacy fallback: defaults to dedicated folder picking.
    static func present(completion: @escaping @MainActor @Sendable ([(url: URL, bookmark: Data)]) -> Void) {
        presentFolder(completion: completion)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Single-URL callback required by iPadOS when allowsMultipleSelection = false.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        handlePickedURLs([url], from: controller)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        handlePickedURLs(urls, from: controller)
    }

    private func handlePickedURLs(_ urls: [URL], from controller: UIDocumentPickerViewController) {
        guard !didFinishHandling else { return }
        didFinishHandling = true

        // Dismiss picker immediately first.
        // CRITICAL: DO NOT nest result processing inside the completion handler of controller.dismiss(animated:completion:).
        // On iPadOS, UIKit silently drops dismiss completions when the remote view service is already transitioning out.
        controller.dismiss(animated: true)

        guard !urls.isEmpty else {
            finish(with: [])
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
        // Dispatch completion asynchronously on MainActor, guaranteeing execution
        Task { @MainActor [weak self] in
            self?.finish(with: capturedResults)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !didFinishHandling else { return }
        didFinishHandling = true
        Logger.shared.log("FolderLinkCoordinator: user cancelled picker", category: "FolderLink", type: .info)
        controller.dismiss(animated: true)
        Task { @MainActor [weak self] in
            self?.finish(with: [])
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

        if rootVC.isBeingDismissed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let safeTop = topViewController() {
                    safeTop.present(picker, animated: true)
                } else {
                    live?.finish(with: [])
                }
            }
            return
        }

        rootVC.present(picker, animated: true)
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
