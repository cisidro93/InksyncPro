import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS File/Folder picker globally, completely bypassing SwiftUI `.sheet`
/// bugs that cause thread locks or frozen "Open" buttons.
final class ImportCoordinator: NSObject, UIDocumentPickerDelegate {

    enum ImportType {
        case files
        case folder
        case json // For settings/exports
        case smartList // For cbl, csv, md, txt
        case unified // Universal hybrid file and folder picker
    }

    private static var live: ImportCoordinator?
    private var completion: (([URL]) -> Void)?
    private var currentType: ImportType = .files

    private override init() {}

    /// Present the picker from the topmost active view controller.
    static func present(type: ImportType = .files, completion: @escaping ([URL]) -> Void) {
        let coordinator = ImportCoordinator()
        coordinator.completion = completion
        coordinator.currentType = type
        ImportCoordinator.live = coordinator

        guard let rootVC = ImportCoordinator.topViewController() else {
            Logger.shared.log("ImportCoordinator: Could not find root view controller.", category: "System", type: .error)
            completion([])
            ImportCoordinator.live = nil
            return
        }

        let supportedTypes: [UTType]
        switch type {
        case .files:
            supportedTypes = [
                UTType(filenameExtension: "cbz") ?? .zip,
                UTType(filenameExtension: "cbr") ?? .archive,
                UTType(filenameExtension: "cb7") ?? .archive,
                .epub, .pdf, .zip, .archive
            ]
        case .unified:
            supportedTypes = [
                UTType(filenameExtension: "cbz") ?? .zip,
                UTType(filenameExtension: "cbr") ?? .archive,
                UTType(filenameExtension: "cb7") ?? .archive,
                .epub, .pdf, .zip, .archive, .folder
            ]
        case .folder:
            supportedTypes = [.folder]
        case .json:
            supportedTypes = [.json]
        case .smartList:
            supportedTypes = [
                .item, .content, .data, .plainText, .commaSeparatedText, .text,
                UTType(filenameExtension: "cbl") ?? .xml,
                UTType(filenameExtension: "csv") ?? .commaSeparatedText,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "txt") ?? .plainText
            ]
        }
        
        let picker: UIDocumentPickerViewController
        if type == .folder {
            let folderTypes: [UTType] = [.folder, .directory]
            picker = UIDocumentPickerViewController(forOpeningContentTypes: folderTypes, asCopy: false)
            picker.allowsMultipleSelection = false
        } else if type == .unified {
            // asCopy:false so we get security-scoped URLs.
            // allowsMultipleSelection:true lets users pick multiple files when browsing inside a folder.
            // .folder in the supported types enables the "Open" button when the user is AT a folder level.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: false)
            picker.allowsMultipleSelection = true
            picker.directoryURL = nil // Let the picker open at the system default location
        } else {
            let asCopy = type == .files || type == .json || type == .smartList
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: asCopy)
            picker.allowsMultipleSelection = (type == .files)
        }
        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true

        Logger.shared.log("ImportCoordinator: Presenting \(type) picker", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }
        
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInitiated).async {
                if self.currentType == .folder {
                    var allFound: [URL] = []
                    for url in urls {
                        let isAccessing = url.startAccessingSecurityScopedResource()
                        allFound.append(contentsOf: ImportCoordinator.processFolderSpiderSync(url: url))
                        if isAccessing { url.stopAccessingSecurityScopedResource() }
                    }
                    DispatchQueue.main.async { self.finish(with: allFound) }
                } else if self.currentType == .unified {
                    // asCopy:false means we hold the security scope and must copy files
                    // to our own staging dir before releasing it.
                    var allFound: [URL] = []
                    let fm = FileManager.default
                    let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
                    let stagingDir = fm.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
                    try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                    
                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            // Folder opened — recursively copy all valid files while scope is active
                            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                                for case let fileURL as URL in enumerator {
                                    guard allowedExts.contains(fileURL.pathExtension.lowercased()) else { continue }
                                    let dest = stagingDir.appendingPathComponent(fileURL.lastPathComponent)
                                    do {
                                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                                        try fm.copyItem(at: fileURL, to: dest)
                                        allFound.append(dest)
                                    } catch {
                                        Logger.shared.log("ImportCoordinator: Copy failed for \(fileURL.lastPathComponent): \(error)", category: "System", type: .warning)
                                    }
                                }
                            }
                        } else if allowedExts.contains(url.pathExtension.lowercased()) {
                            // Single file — copy to staging while scope is active
                            let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
                            do {
                                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                                try fm.copyItem(at: url, to: dest)
                                allFound.append(dest)
                            } catch {
                                Logger.shared.log("ImportCoordinator: Single file copy failed for \(url.lastPathComponent): \(error)", category: "System", type: .warning)
                            }
                        }
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    DispatchQueue.main.async { self.finish(with: allFound) }
                } else {
                    DispatchQueue.main.async {
                        self.finish(with: urls)
                    }
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Private Methods
    
    static func processFolderSpiderSync(url: URL) -> [URL] {
        var foundURLs: [URL] = []
        let validExts = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Folder_Spider_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if validExts.contains(fileURL.pathExtension.lowercased()) {
                    let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                        try fm.copyItem(at: fileURL, to: destURL)
                        foundURLs.append(destURL)
                    } catch {
                        Logger.shared.log("ImportCoordinator: Spider Copy Failed for \(fileURL.lastPathComponent): \(error)", category: "System", type: .warning)
                    }
                }
            }
        }
        
        return foundURLs
    }

    private func finish(with urls: [URL]) {
        completion?(urls)
        completion = nil
        ImportCoordinator.live = nil
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
