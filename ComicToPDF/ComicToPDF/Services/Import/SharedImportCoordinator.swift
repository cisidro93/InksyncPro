import Foundation
import Combine
import UIKit

// MARK: - SharedImportCoordinator
//
// Single-responsibility actor that owns the entire shared-import pipeline:
//
//  1.  Share Extension writes files into AppGroup/<any>/ShareStaging/ or
//      AppGroup/<any>/Inbox/  and sets `pendingShareImportTimestamp` in each
//      AppGroup UserDefaults suite.
//
//  2.  On foreground / URL open / AppDelegate callback, the host app calls
//      `coordinateImport(source:)`.  This actor moves every staged file into
//      the canonical InksyncVault/Inbox/ and resolves the final filenames.
//
//  3.  It publishes `ingestedFileNames` so ContentView can auto-select the
//      book after a scan.
//
// Why an actor?
//  - FileManager operations are not concurrency-safe from multiple callers.
//  - The polling retry loop must be serialized so we never double-move a file.

@MainActor
final class SharedImportCoordinator: ObservableObject {

    static let shared = SharedImportCoordinator()

    // UI-observable set of filenames that were just ingested during this launch.
    @Published private(set) var pendingAutoSelectFilenames: Set<String> = []

    // Weak reference to ConversionManager, injected at app startup.
    // Used to call scanLibrary() directly after ingest so the library
    // is fully populated BEFORE we fire .ShareImportReceived.
    weak var conversionManager: ConversionManager?

    private let appGroupIDs = [
        "group.com.antigravity.InksyncPro",
        "group.com.antigravity.ComicToPDF",
        "group.com.antigravity.inksync"
    ]

    private let supportedExtensions: Set<String> = [
        "pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip", "rar", "7z", "tar", "txt", "md"
    ]

    private var isIngesting = false
    private var inFlightDirectOpens: Set<String> = []

    // MARK: - Entry Points

    /// Consolidated entry point for ALL external URL handling (custom schemes and file URLs).
    func handleIncomingURL(_ url: URL) async {
        Logger.shared.log("SharedImportCoordinator: handleIncomingURL '\(url.absoluteString)'", category: "Import", type: .info)
        if url.scheme == "inksyncpro" || url.scheme == "inksync" {
            var targetFile: String? = nil
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                targetFile = components.queryItems?.first(where: { $0.name == "file" })?.value
            }
            coordinateImport(targetFilename: targetFile, retryCount: 5, retryDelaySeconds: 0.3)
        } else if url.isFileURL {
            await handleDirectFileOpen(url: url, autoOpen: true)
        }
    }

    /// Direct async entry point used by LibraryScanner and background tasks.
    func coordinateImportDirect() async {
        let ingestedNames = await self.moveStagedFilesToInbox()
        if !ingestedNames.isEmpty {
            for name in ingestedNames {
                self.pendingAutoSelectFilenames.insert(name)
            }
            // Capture IDs before leaving MainActor isolation
            let groupIDs = appGroupIDs
            Self.clearPendingShareFlagsFor(groupIDs: groupIDs)
            Logger.shared.log(
                "SharedImportCoordinator: Direct imported \(ingestedNames.count) file(s)",
                category: "Import", type: .success
            )
        }
    }

    /// Called by ContentView's willEnterForeground observer, AppDelegate URL handler,
    /// scenePhase changes, and the `inksyncpro://` deep-link handler. Safe to call
    /// multiple times — it debounces internally.
    func coordinateImport(targetFilename: String? = nil, retryCount: Int = 3, retryDelaySeconds: Double = 0.5) {
        guard !isIngesting else { return }
        isIngesting = true
        let groupIDs = appGroupIDs
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ingestedNames = await self.ingestWithRetry(maxAttempts: retryCount, retryDelay: retryDelaySeconds)
            await MainActor.run {
                for name in ingestedNames {
                    self.pendingAutoSelectFilenames.insert(name)
                }
                if !ingestedNames.isEmpty {
                    Self.clearPendingShareFlagsFor(groupIDs: groupIDs)
                    Logger.shared.log(
                        "SharedImportCoordinator: Completed import of \(ingestedNames.count) file(s)",
                        category: "Import", type: .success
                    )

                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                    let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)

                    let manager = self.conversionManager ?? ConversionManager.shared
                    var firstPDF: ConvertedPDF? = nil

                    for (idx, name) in ingestedNames.enumerated() {
                        let fileURL = inboxDir.appendingPathComponent(name)
                        let shouldOpen = (name == targetFilename) || (targetFilename == nil && idx == 0)
                        if let pdf = manager?.registerDirectFile(at: fileURL, autoOpen: shouldOpen) {
                            if shouldOpen && firstPDF == nil {
                                firstPDF = pdf
                            }
                        }
                    }

                    manager?.scanLibrary()

                    NotificationCenter.default.post(
                        name: NSNotification.Name("InksyncPro.ShareImportReceived"),
                        object: firstPDF
                    )
                    NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
                } else {
                    Logger.shared.log(
                        "SharedImportCoordinator: No files ingested — leaving flags set for next foreground retry.",
                        category: "Import", type: .warning
                    )
                }
                self.isIngesting = false
            }
        }
    }

    /// Centralized, failsafe direct file:// ingestion method.
    /// Handles security-scoped access, coordination, destination placement in InksyncVault/Inbox,
    /// direct library registration, and instant presentation in the reader.
    @discardableResult
    func handleDirectFileOpen(url: URL, autoOpen: Bool = true) async -> URL? {
        let pathKey = url.path
        if inFlightDirectOpens.contains(pathKey) {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
            let dest = inboxDir.appendingPathComponent(url.lastPathComponent)
            if autoOpen, let manager = conversionManager ?? ConversionManager.shared {
                manager.registerDirectFile(at: dest, autoOpen: true)
            }
            return dest
        }
        inFlightDirectOpens.insert(pathKey)
        defer { inFlightDirectOpens.remove(pathKey) }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let filename = url.lastPathComponent
        let dest = inboxDir.appendingPathComponent(filename)

        // If file is already at destination and valid, register and autoOpen
        if dest.path == url.path && FileManager.default.fileExists(atPath: dest.path) {
            registerDirectlyOpenedFile(at: dest)
            if let manager = conversionManager ?? ConversionManager.shared {
                manager.registerDirectFile(at: dest, autoOpen: autoOpen)
            }
            NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
            return dest
        }

        try? FileManager.default.removeItem(at: dest)

        var copySuccess = false

        // Coordinate read via NSFileCoordinator
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: .withoutChanges, error: nil
        ) { safeURL in
            let innerAccess = safeURL.startAccessingSecurityScopedResource()
            defer { if innerAccess { safeURL.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: safeURL, to: dest)
                copySuccess = true
            } catch {
                if let data = try? Data(contentsOf: safeURL, options: .alwaysMapped) {
                    copySuccess = (try? data.write(to: dest, options: .atomic)) != nil
                }
            }
        }

        // Direct stream fallback
        if !copySuccess, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            copySuccess = (try? data.write(to: dest, options: .atomic)) != nil
        }

        guard copySuccess else {
            Logger.shared.log(
                "SharedImportCoordinator: Failed to copy file \(filename) to InksyncVault/Inbox",
                category: "Import", type: .error
            )
            return nil
        }

        Logger.shared.log(
            "SharedImportCoordinator: Successfully ingested direct file '\(filename)' → InksyncVault/Inbox",
            category: "Import", type: .success
        )

        registerDirectlyOpenedFile(at: dest)
        let manager = conversionManager ?? ConversionManager.shared
        let openedPDF = manager.registerDirectFile(at: dest, autoOpen: autoOpen)
        manager.scanLibrary()
        NotificationCenter.default.post(
            name: NSNotification.Name("InksyncPro.DirectFileOpenReceived"),
            object: openedPDF
        )
        NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
        return dest
    }

    /// Called when a direct file:// URL is handed to the app (Open With, Files.app, AirDrop).
    /// The caller must have already copied the file to InksyncVault/Inbox.
    func registerDirectlyOpenedFile(at url: URL) {
        let filename = url.lastPathComponent
        if !filename.isEmpty {
            pendingAutoSelectFilenames.insert(filename)
        }
    }

    // MARK: - Private: Retry Loop

    nonisolated private func ingestWithRetry(maxAttempts: Int, retryDelay: Double) async -> [String] {
        var allIngested: [String] = []
        // Progressive retry schedule: each attempt doubles the wait, giving the
        // Share Extension process more time to finish writing large files.
        // e.g. with retryDelay=0.5 → waits of 0.5, 1.0, 2.0, 4.0 seconds.
        var currentDelay = retryDelay
        for attempt in 1...maxAttempts {
            let names = await moveStagedFilesToInbox()
            if !names.isEmpty {
                allIngested.append(contentsOf: names)
                Logger.shared.log(
                    "SharedImportCoordinator: Ingested \(names.count) file(s) on attempt \(attempt)",
                    category: "Import", type: .success
                )
                return allIngested
            }
            // No files found yet — the extension process may still be writing.
            // Use exponential back-off so large file copies get enough time.
            if attempt < maxAttempts {
                Logger.shared.log(
                    "SharedImportCoordinator: Attempt \(attempt)/\(maxAttempts) — no staged files yet, waiting \(String(format: "%.1f", currentDelay))s",
                    category: "Import"
                )
                try? await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                currentDelay = min(currentDelay * 2, 8.0) // cap at 8 seconds
            }
        }
        Logger.shared.log(
            "SharedImportCoordinator: No staged files found after \(maxAttempts) attempts — " +
            "will rely on next foreground scan.",
            category: "Import", type: .warning
        )
        return allIngested
    }

    // MARK: - Private: File Movement

    nonisolated static func getAllSearchContainers() -> [URL] {
        let fm = FileManager.default
        var containers: [URL] = []
        let groupIDs = [
            "group.com.antigravity.InksyncPro",
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync"
        ]
        for id in groupIDs {
            if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: id) {
                if !containers.contains(container) {
                    containers.append(container)
                }
            }
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first, !containers.contains(docs) {
            containers.append(docs)
        }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first, !containers.contains(appSupport) {
            containers.append(appSupport)
        }
        let tmp = fm.temporaryDirectory
        if !containers.contains(tmp) {
            containers.append(tmp)
        }
        return containers
    }

    nonisolated private func moveStagedFilesToInbox() async -> [String] {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        var ingestedFilenames: Set<String> = []
        var visitedContainers: Set<URL> = []

        let searchContainers = Self.getAllSearchContainers()
        for container in searchContainers {
            if visitedContainers.contains(container) { continue }
            visitedContainers.insert(container)

            let stagingDirs = [
                container.appendingPathComponent("ShareStaging"),
                container.appendingPathComponent("Inbox"),
                container.appendingPathComponent("PendingConversions")
            ]

            for stagingDir in stagingDirs {
                guard let enumerator = fm.enumerator(
                    at: stagingDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                          !isDir.boolValue
                    else { continue }

                    let ext = fileURL.pathExtension.lowercased()

                    // Delete manifest files, they are not library items.
                    if ext == "json" || fileURL.lastPathComponent.hasSuffix(".manifest.json") {
                        try? fm.removeItem(at: fileURL)
                        continue
                    }

                    // Map zip/rar aliases to canonical comic extensions.
                    var canonicalExt: String
                    switch ext {
                    case "zip":     canonicalExt = "cbz"
                    case "rar":     canonicalExt = "cbr"
                    case "7z":      canonicalExt = "cb7"
                    default:        canonicalExt = ext
                    }

                    // If extension is missing or unrecognized, detect from magic bytes
                    if !supportedExtensions.contains(canonicalExt) || canonicalExt.isEmpty || canonicalExt == "tmp" {
                        if let detected = Self.detectExtensionFromMagicBytes(fileURL) {
                            canonicalExt = detected
                        }
                    }

                    guard supportedExtensions.contains(canonicalExt) else { continue }

                    // Ensure the file is completely written before moving.
                    guard await isFileSettled(at: fileURL) else {
                        Logger.shared.log(
                            "SharedImportCoordinator: Skipping unsettled file: \(fileURL.lastPathComponent)",
                            category: "Import", type: .warning
                        )
                        continue
                    }

                    let base = (fileURL.deletingPathExtension().lastPathComponent)
                    let destFilename = "\(base).\(canonicalExt)"
                    let dest = inboxDir.appendingPathComponent(destFilename)

                    func getFileSize(at path: String) -> Int64 {
                        guard let attrs = try? fm.attributesOfItem(atPath: path),
                              let val = attrs[.size] else { return 0 }
                        return (val as? NSNumber)?.int64Value ?? (val as? Int64) ?? (val as? UInt64).map(Int64.init) ?? 0
                    }

                    // Skip if an identical file is already in the inbox (dedup).
                    if fm.fileExists(atPath: dest.path) {
                        let sourceSize = getFileSize(at: fileURL.path)
                        let destSize = getFileSize(at: dest.path)
                        if sourceSize > 0 && sourceSize == destSize {
                            try? fm.removeItem(at: fileURL)
                            ingestedFilenames.insert(destFilename)
                            Logger.shared.log(
                                "SharedImportCoordinator: Duplicate recognized & linked: \(destFilename)",
                                category: "Import"
                            )
                            continue
                        }
                        try? fm.removeItem(at: dest)
                    }

                    do {
                        try fm.moveItem(at: fileURL, to: dest)
                        ingestedFilenames.insert(destFilename)
                        Logger.shared.log(
                            "SharedImportCoordinator: Moved '\(destFilename)' to InksyncVault/Inbox",
                            category: "Import", type: .success
                        )
                    } catch {
                        // Move failed (cross-device) — fall back to copy-then-delete.
                        if let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) {
                            do {
                                try data.write(to: dest, options: .atomic)
                                try? fm.removeItem(at: fileURL)
                                ingestedFilenames.insert(destFilename)
                                Logger.shared.log(
                                    "SharedImportCoordinator: Streamed '\(destFilename)' to InksyncVault/Inbox",
                                    category: "Import", type: .success
                                )
                            } catch {
                                Logger.shared.log(
                                    "SharedImportCoordinator: Failed to ingest '\(fileURL.lastPathComponent)': \(error)",
                                    category: "Import", type: .error
                                )
                            }
                        }
                    }
                }
            }
        }
        return Array(ingestedFilenames)
    }

    // MARK: - Private: File Settle Check

    /// Returns true only when the file size is non-zero AND has not changed in the
    /// last 150ms — meaning the extension process has finished writing it.
    nonisolated private func isFileSettled(at url: URL) async -> Bool {
        let fm = FileManager.default
        guard let attrs1 = try? fm.attributesOfItem(atPath: url.path),
              let sizeVal1 = attrs1[.size]
        else { return false }
        let size1 = (sizeVal1 as? NSNumber)?.int64Value ?? (sizeVal1 as? Int64) ?? (sizeVal1 as? UInt64).map(Int64.init) ?? 0
        guard size1 > 0 else { return false }

        // For very small files (<1MB) we trust immediately.
        if size1 < 1_048_576 { return true }

        // For larger files: compare size after 150ms async non-blocking sleep.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let attrs2 = try? fm.attributesOfItem(atPath: url.path),
              let sizeVal2 = attrs2[.size]
        else { return false }
        let size2 = (sizeVal2 as? NSNumber)?.int64Value ?? (sizeVal2 as? Int64) ?? (sizeVal2 as? UInt64).map(Int64.init) ?? 0
        return size1 == size2
    }

    // MARK: - Private: Clear App Group Flags

    /// Swift 6 fix: `nonisolated` methods cannot access `@MainActor`-isolated stored properties.
    /// The caller captures `appGroupIDs` on the MainActor and passes it as a value-type argument.
    nonisolated static func clearPendingShareFlagsFor(groupIDs: [String]) {
        for groupID in groupIDs {
            if let ud = UserDefaults(suiteName: groupID) {
                ud.removeObject(forKey: "pendingShareImportTimestamp")
                ud.removeObject(forKey: "hasPendingShareImport")
                ud.synchronize()
            }
        }
    }

    // MARK: - Public: Consume after auto-select

    @discardableResult
    func consumeAutoSelectFilenames() -> Set<String> {
        let names = pendingAutoSelectFilenames
        pendingAutoSelectFilenames = []
        return names
    }

    func hasPendingShareImport() -> Bool {
        if appGroupIDs.contains(where: {
            (UserDefaults(suiteName: $0)?.double(forKey: "pendingShareImportTimestamp") ?? 0) > 0 ||
            UserDefaults(suiteName: $0)?.bool(forKey: "hasPendingShareImport") == true
        }) {
            return true
        }

        // Also check physical directories in App Groups and fallbacks for any staged files
        let fm = FileManager.default
        let searchContainers = Self.getAllSearchContainers()
        for container in searchContainers {
            let stagingDirs = [
                container.appendingPathComponent("ShareStaging"),
                container.appendingPathComponent("Inbox"),
                container.appendingPathComponent("PendingConversions")
            ]
            for dir in stagingDirs {
                if let contents = try? fm.contentsOfDirectory(atPath: dir.path), !contents.isEmpty {
                    let validFiles = contents.filter { !$0.hasSuffix(".manifest.json") && !$0.hasPrefix(".") }
                    if !validFiles.isEmpty {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Magic Byte Helper

    nonisolated static func detectExtensionFromMagicBytes(_ fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let data = try? fileHandle.read(upToCount: 2000) else { return nil }
        defer { try? fileHandle.close() }
        guard data.count >= 4 else { return nil }

        // PDF (%PDF)
        if data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46 { return "pdf" }
        // RAR (Rar!)
        if data[0] == 0x52 && data[1] == 0x61 && data[2] == 0x72 && data[3] == 0x21 { return "cbr" }
        // ZIP / CBZ / EPUB (PK\x03\x04 or PK\x05\x06)
        if (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04) ||
           (data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x05 && data[3] == 0x06) {
            let header = String(decoding: data.prefix(500), as: UTF8.self)
            if header.contains("mimetype") && (header.contains("epub+zip") || header.contains("epub")) {
                return "epub"
            }
            return "cbz"
        }
        // 7-Zip (7z\xBC\xAF\x27\x1C)
        if data[0] == 0x37 && data[1] == 0x7A && data[2] == 0xBC && data[3] == 0xAF {
            return "cb7"
        }
        return nil
    }
}
