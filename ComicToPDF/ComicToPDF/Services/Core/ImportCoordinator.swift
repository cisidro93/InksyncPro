import UIKit
import UniformTypeIdentifiers

/// Presents a native iOS File/Folder picker globally, completely bypassing SwiftUI `.sheet`
/// bugs that cause thread locks or frozen "Open" buttons.
@MainActor
final class ImportCoordinator: NSObject, UIDocumentPickerDelegate {

    enum ImportType {
        case files
        case folder
        case json       // For settings/exports
        case smartList  // For cbl, csv, md, txt
        case unified    // Universal hybrid file and folder picker
    }

    // Strong reference held so ARC doesn't collect the coordinator before the delegate fires.
    // Always replaced — never guarded — so stale references can never deadlock the UI.
    private static var live: ImportCoordinator?
    private var completion: (([URL]) -> Void)?
    private var currentType: ImportType = .files

    private override init() {}

    // MARK: - Present

    /// Present the file picker from the topmost active view controller.
    /// If a stale reference exists it is replaced immediately; taps are never silently dropped.
    static func present(type: ImportType = .files, completion: @escaping ([URL]) -> Void) {
        let coordinator = ImportCoordinator()
        coordinator.completion = completion
        coordinator.currentType = type
        ImportCoordinator.live = coordinator // always replace, never guard

        guard let rootVC = ImportCoordinator.topViewController() else {
            Logger.shared.log("ImportCoordinator: No root view controller found.", category: "System", type: .error)
            completion([])
            ImportCoordinator.live = nil
            return
        }

        let supportedTypes: [UTType]
        switch type {
        case .json:
            supportedTypes = [.json]
        case .smartList:
            // UTType.content = base type for ALL readable file content (text, CSV, data) but
            // explicitly EXCLUDES directories. Using .item (which includes .folder) causes
            // iPadOS to enter a hybrid browse/select mode that suppresses selection circles.
            // We validate the actual file extension in the parser, so broad matching is safe.
            supportedTypes = [.content]
        default:
            // Unified Legacy Forward-Port (0bb6b38)
            supportedTypes = [
                .pdf, .zip, .folder, .archive,
                UTType(filenameExtension: "epub") ?? .epub,
                UTType(filenameExtension: "cbz") ?? .zip,
                UTType(filenameExtension: "cbr") ?? .archive,
                UTType(filenameExtension: "cb7") ?? .archive
            ].compactMap { $0 }
        }

        let picker: UIDocumentPickerViewController

        if type == .json {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
            picker.allowsMultipleSelection = false
        } else {
            // Legacy 0bb6b38 Perfection: Unified Picker handles BOTH files and folders simultaneously natively.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
            picker.allowsMultipleSelection = true
        }

        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .fullScreen
        Logger.shared.log("ImportCoordinator: Presenting structured picker payload natively.", category: "System")
        rootVC.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    /// Deprecated single-URL delegate (iOS < 11). iOS still calls THIS (not the multi-URL variant)
    /// when allowsMultipleSelection=false and a folder is selected via the .folder picker.
    /// The working binary explicitly implements this in FolderPickerV.Coordinator.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else {
            finish(with: [])
            return
        }

        // Dismiss the picker immediately — asCopy:false never auto-dismisses.
        // We do NOT use a completion block so processing is not gated on the animation.
        controller.dismiss(animated: true)
        
        let type = self.currentType
        
        let stagingTask = Task.detached(priority: .userInitiated) { () -> [URL] in
            if type == .json || type == .smartList {
                return urls
            }

            // --- Parallel Staging: Phase 1 enumerate, Phase 2 concurrent copy ---
            let fm = FileManager.default
            let allowedExts: Set<String> = ["cbz", "cbr", "cb7", "epub", "zip", "pdf"]

            let stagingDir = fm.temporaryDirectory.appendingPathComponent("InksyncStaging_\(UUID().uuidString)")
            try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            var securedURLs: [URL] = []
            for url in urls {
                if url.startAccessingSecurityScopedResource() {
                    securedURLs.append(url)
                }
            }
            defer {
                for url in securedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // ── Phase 1: Collect candidate (source, dest) pairs without copying ──
            // Enumeration is cheap (metadata only); we yield every 25 items to keep
            // the Swift runtime scheduler responsive during large folder scans.
            struct CopyJob {
                let source: URL
                let dest: URL
            }
            var jobs: [CopyJob] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    // Recursively spider — metadata-only, no I/O
                    let keys: [URLResourceKey] = [.isDirectoryKey]
                    if let enumerator = fm.enumerator(at: url,
                                                       includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles]) {
                        var enumCount = 0
                        while let fileURL = enumerator.nextObject() as? URL {
                            enumCount += 1
                            if enumCount % 25 == 0 { await Task.yield() }

                            guard let rsrc = try? fileURL.resourceValues(forKeys: Set(keys)),
                                  rsrc.isDirectory == false else { continue }
                            guard allowedExts.contains(fileURL.pathExtension.lowercased()) else { continue }

                            // Preserve native structure for SeriesNameParser Context
                            let originalParent = fileURL.deletingLastPathComponent().lastPathComponent
                            let destFolder = stagingDir.appendingPathComponent(originalParent)
                            try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                            jobs.append(CopyJob(source: fileURL,
                                                dest: destFolder.appendingPathComponent(fileURL.lastPathComponent)))
                        }
                    }
                } else {
                    // Standard single-file selection
                    if allowedExts.contains(url.pathExtension.lowercased()) {
                        let originalParent = url.deletingLastPathComponent().lastPathComponent
                        let destFolder = stagingDir.appendingPathComponent(originalParent)
                        try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                        jobs.append(CopyJob(source: url,
                                            dest: destFolder.appendingPathComponent(url.lastPathComponent)))
                    }
                }
            }

            // ── Phase 2: Concurrent copy — up to 8 in-flight (APFS parallel I/O) ──
            // FileManager.copyItem is thread-safe for independent source/dest pairs.
            let maxConcurrent = 8
            var foundURLs: [URL] = []

            await withTaskGroup(of: URL?.self) { group in
                var inFlight = 0

                for job in jobs {
                    // Back-pressure: drain one slot before adding when at capacity
                    if inFlight >= maxConcurrent {
                        if let result = await group.next() {
                            if let url = result { foundURLs.append(url) }
                            inFlight -= 1
                        }
                    }

                    let src = job.source
                    let dst = job.dest
                    group.addTask {
                        do {
                            // Use FileManager.default inline — avoids capturing the non-Sendable
                            // local `fm` reference across the task group isolation boundary.
                            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                            try FileManager.default.copyItem(at: src, to: dst)
                            return dst
                        } catch {
                            Logger.shared.log("ImportCoordinator: Copy failed \(src.lastPathComponent)",
                                              category: "System", type: .warning)
                            return nil
                        }
                    }
                    inFlight += 1
                }

                // Drain remaining in-flight tasks
                for await result in group {
                    if let url = result { foundURLs.append(url) }
                }
            }

            return foundURLs
        }
        
        Task {
            let foundURLs = await stagingTask.value
            self.finish(with: foundURLs)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Logger.shared.log("ImportCoordinator: Picker cancelled.", category: "System", type: .warning)
        finish(with: [])
    }

    // MARK: - Helpers



    private func finish(with urls: [URL]) {
        completion?(urls)
        completion = nil
        ImportCoordinator.live = nil
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
