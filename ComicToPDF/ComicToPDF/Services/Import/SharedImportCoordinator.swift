import Foundation
import Combine
import UIKit
import UniformTypeIdentifiers

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
    private var pendingTargetFilenames: [String] = []

    // MARK: - Entry Points

    /// Consolidated entry point for ALL external URL handling (custom schemes and file URLs).
    func handleIncomingURL(_ url: URL) async {
        Logger.shared.log("SharedImportCoordinator: handleIncomingURL '\(url.absoluteString)' (scheme: \(url.scheme ?? "none"), isFileURL: \(url.isFileURL))", category: "ShareImport", type: .info)
        if url.scheme == "inksyncpro" || url.scheme == "inksync" {
            var targetFile: String? = nil
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                targetFile = components.queryItems?.first(where: { $0.name == "file" })?.value
            }
            Logger.shared.log("SharedImportCoordinator: Handover received from Share Extension deep link. Target: '\(targetFile ?? "all pending")'", category: "ShareImport", type: .info)
            coordinateImport(targetFilename: targetFile, retryCount: 5, retryDelaySeconds: 0.3)
        } else if url.isFileURL {
            Logger.shared.log("SharedImportCoordinator: Direct external file URL received from external app/AirDrop: '\(url.lastPathComponent)'", category: "ShareImport", type: .info)
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
            let groupIDs = appGroupIDs
            Self.clearPendingShareFlagsFor(groupIDs: groupIDs)

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
            let manager = self.conversionManager ?? ConversionManager.shared

            for name in ingestedNames {
                let fileURL = inboxDir.appendingPathComponent(name)
                manager.registerDirectFile(at: fileURL, autoOpen: false)
            }
            manager.saveLibrary()

            Logger.shared.log(
                "SharedImportCoordinator: Direct imported and registered \(ingestedNames.count) file(s)",
                category: "ShareImport", type: .success
            )
        }
    }

    /// Called by ContentView's willEnterForeground observer, AppDelegate URL handler,
    /// scenePhase changes, and the `inksyncpro://` deep-link handler. Safe to call
    /// multiple times — queues concurrent requests and debounces internally.
    func coordinateImport(targetFilename: String? = nil, retryCount: Int = 3, retryDelaySeconds: Double = 0.5) {
        if let target = targetFilename, !target.isEmpty {
            pendingTargetFilenames.append(target)
        }
        guard !isIngesting else {
            Logger.shared.log(
                "SharedImportCoordinator: Ingestion already active — queued target '\(targetFilename ?? "all")' for follow-up drain",
                category: "ShareImport", type: .info
            )
            return
        }
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
                        "SharedImportCoordinator: Completed import of \(ingestedNames.count) file(s): \(ingestedNames.joined(separator: ", "))",
                        category: "ShareImport", type: .success
                    )

                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                    let inboxDir = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)

                    let manager = self.conversionManager ?? ConversionManager.shared
                    var firstPDF: ConvertedPDF? = nil

                    let activeTargets = Set(self.pendingTargetFilenames)
                    self.pendingTargetFilenames.removeAll()

                    for (idx, name) in ingestedNames.enumerated() {
                        let fileURL = inboxDir.appendingPathComponent(name)
                        let shouldOpen = activeTargets.contains(name) || (name == targetFilename) || (activeTargets.isEmpty && targetFilename == nil && idx == 0)
                        let pdf = manager.registerDirectFile(at: fileURL, autoOpen: shouldOpen)
                        if shouldOpen && firstPDF == nil {
                            firstPDF = pdf
                        }
                    }

                    if firstPDF == nil, let firstName = ingestedNames.first {
                        firstPDF = manager.convertedPDFs.first(where: { $0.url.lastPathComponent == firstName })
                    }

                    manager.scanLibrary()

                    NotificationCenter.default.post(
                        name: NSNotification.Name("InksyncPro.ShareImportReceived"),
                        object: firstPDF
                    )
                    NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
                    let toastMsg = ingestedNames.count == 1 ? "Added '\(ingestedNames[0])' to Library" : "Added \(ingestedNames.count) books to Library"
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": toastMsg])
                } else {
                    Logger.shared.log(
                        "SharedImportCoordinator: No files ingested — leaving flags set for next foreground retry.",
                        category: "ShareImport", type: .warning
                    )
                }
                self.isIngesting = false

                // If new targets arrived while processing, trigger a follow-up drain pass
                if !self.pendingTargetFilenames.isEmpty {
                    Logger.shared.log("SharedImportCoordinator: Draining \(self.pendingTargetFilenames.count) pending targets in follow-up pass", category: "ShareImport", type: .info)
                    self.coordinateImport(targetFilename: nil, retryCount: 3, retryDelaySeconds: 0.3)
                }
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
            if autoOpen {
                let manager = conversionManager ?? ConversionManager.shared
                manager.registerDirectFile(at: dest, autoOpen: true)
            }
            return dest
        }
        inFlightDirectOpens.insert(pathKey)
        defer { inFlightDirectOpens.remove(pathKey) }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Ensure the file is completely written before copying (e.g. AirDrop / share sheet transfers)
        guard await isFileSettled(at: url) else {
            Logger.shared.log(
                "SharedImportCoordinator: Direct open file is not settled yet or zero-byte: \(url.lastPathComponent)",
                category: "Import", type: .warning
            )
            return nil
        }

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
            let manager = conversionManager ?? ConversionManager.shared
            manager.registerDirectFile(at: dest, autoOpen: autoOpen)
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
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Added '\(filename)' to Library"])

        // Clean up temporary handoff copies left in system Documents/Inbox to prevent disk bloat
        if url.path.contains("/Documents/Inbox/") && url.path != dest.path {
            try? FileManager.default.removeItem(at: url)
            Logger.shared.log("SharedImportCoordinator: Cleaned up temporary system inbox file at \(url.lastPathComponent)", category: "Import", type: .info)
        }

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

        // Sideload / Unsigned IPA Fallback Bridge: Check UIPasteboard.general (supports both multi-file items and single-file data)
        await MainActor.run {
            let fileTypeKey = "com.antigravity.InksyncPro.sharedFileData"
            let fileNameKey = "com.antigravity.InksyncPro.sharedFileName"

            // 1. Check multi-item pasteboard array
            for item in UIPasteboard.general.items {
                let pbData: Data? = (item[fileTypeKey] as? Data)
                    ?? (item[UTType.data.identifier] as? Data)
                    ?? (item[UTType.pdf.identifier] as? Data)

                if let pbData, !pbData.isEmpty {
                    var pbName = (item[fileNameKey] as? String)
                        ?? (item[fileNameKey] as? Data).flatMap({ String(data: $0, encoding: .utf8) })
                        ?? (item[UTType.utf8PlainText.identifier] as? String)
                        ?? (item[UTType.plainText.identifier] as? String)

                    if pbName == nil || pbName?.isEmpty == true {
                        pbName = self.pendingTargetFilenames.first
                    }

                    let resolvedName: String = {
                        if let name = pbName, !name.isEmpty { return name }
                        let ext = Self.detectExtensionFromBytes(pbData) ?? "pdf"
                        return "SharedDocument_\(Int(Date().timeIntervalSince1970)).\(ext)"
                    }()

                    let dest = inboxDir.appendingPathComponent(resolvedName)
                    if (try? pbData.write(to: dest, options: .atomic)) != nil {
                        ingestedFilenames.insert(resolvedName)
                        Logger.shared.log("SharedImportCoordinator: Ingested file '\(resolvedName)' (\(pbData.count) bytes) from UIPasteboard multi-item bridge", category: "ShareImport", type: .success)
                    }
                }
            }

            // 2. Check root-level pasteboard data (backward-compatibility fallback)
            if ingestedFilenames.isEmpty {
                let rootData = UIPasteboard.general.data(forPasteboardType: fileTypeKey)
                    ?? UIPasteboard.general.data(forPasteboardType: UTType.data.identifier)
                    ?? UIPasteboard.general.data(forPasteboardType: UTType.pdf.identifier)

                if let rootData, !rootData.isEmpty {
                    let rootName = (UIPasteboard.general.value(forPasteboardType: fileNameKey) as? String)
                        ?? UIPasteboard.general.data(forPasteboardType: fileNameKey).flatMap({ String(data: $0, encoding: .utf8) })
                        ?? UIPasteboard.general.string
                        ?? self.pendingTargetFilenames.first
                        ?? {
                            let ext = Self.detectExtensionFromBytes(rootData) ?? "pdf"
                            return "SharedDocument_\(Int(Date().timeIntervalSince1970)).\(ext)"
                        }()

                    let dest = inboxDir.appendingPathComponent(rootName)
                    if (try? rootData.write(to: dest, options: .atomic)) != nil {
                        ingestedFilenames.insert(rootName)
                        Logger.shared.log("SharedImportCoordinator: Ingested file '\(rootName)' (\(rootData.count) bytes) from UIPasteboard root bridge", category: "ShareImport", type: .success)
                    }
                }
            }

            if !ingestedFilenames.isEmpty {
                // Cleanly remove ONLY our shared import types after successful ingestion without wiping user's text clipboard
                UIPasteboard.general.items = UIPasteboard.general.items.compactMap { item in
                    var filtered = item
                    filtered.removeValue(forKey: fileTypeKey)
                    filtered.removeValue(forKey: fileNameKey)
                    // If the item only contained our data bridge keys, drop it completely
                    if filtered.count <= 2 && (filtered[UTType.data.identifier] != nil || filtered[UTType.utf8PlainText.identifier] != nil) {
                        return nil
                    }
                    return filtered.isEmpty ? nil : filtered
                }
                UIPasteboard.general.setData(Data(), forPasteboardType: fileTypeKey)
                UIPasteboard.general.setValue("", forPasteboardType: fileNameKey)
            }
        }

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

                    // Deduplication & Protection: Never delete a valid destination file!
                    if fm.fileExists(atPath: dest.path) {
                        let sourceSize = getFileSize(at: fileURL.path)
                        let destSize = getFileSize(at: dest.path)
                        if destSize > 0 && (sourceSize == destSize || sourceSize == 0) {
                            // Destination is already complete and valid! Clean up redundant staging copy.
                            try? fm.removeItem(at: fileURL)
                            ingestedFilenames.insert(destFilename)
                            continue
                        }
                        // If source is strictly larger and dest was partial, replace dest safely:
                        if sourceSize > destSize {
                            try? fm.removeItem(at: dest)
                        } else {
                            // Existing dest is larger/valid, don't overwrite with smaller partial file!
                            try? fm.removeItem(at: fileURL)
                            ingestedFilenames.insert(destFilename)
                            continue
                        }
                    }

                    // Attempt moveItem first, followed by copyItem + removeItem
                    var didIngest = false
                    do {
                        try fm.moveItem(at: fileURL, to: dest)
                        didIngest = true
                    } catch {
                        do {
                            try fm.copyItem(at: fileURL, to: dest)
                            try? fm.removeItem(at: fileURL)
                            didIngest = true
                        } catch {
                            // Stream fallback with mappedIfSafe (no alwaysMapped memory spikes)
                            if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
                                if (try? data.write(to: dest, options: .atomic)) != nil {
                                    try? fm.removeItem(at: fileURL)
                                    didIngest = true
                                }
                            }
                        }
                    }

                    if didIngest {
                        ingestedFilenames.insert(destFilename)
                        Logger.shared.log(
                            "SharedImportCoordinator: Moved '\(destFilename)' to InksyncVault/Inbox",
                            category: "Import", type: .success
                        )
                    }
                }
            }
        }
        return Array(ingestedFilenames)
    }

    // MARK: - Private: File Settle Check

    /// Returns true only when the file size is non-zero AND has stabilized
    /// across two non-blocking measurements — ensuring active AirDrop or cross-app transfers are complete.
    nonisolated private func isFileSettled(at url: URL) async -> Bool {
        let fm = FileManager.default
        var attempts = 0
        let maxAttempts = 10

        while attempts < maxAttempts {
            attempts += 1
            if let attrs1 = try? fm.attributesOfItem(atPath: url.path),
               let sizeVal1 = attrs1[.size] {
                let size1 = (sizeVal1 as? NSNumber)?.int64Value ?? (sizeVal1 as? Int64) ?? (sizeVal1 as? UInt64).map(Int64.init) ?? 0
                if size1 > 0 {
                    // For very small files (<1MB) accept if stable or after 1 retry
                    if size1 < 1_048_576 && attempts > 1 { return true }

                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if let attrs2 = try? fm.attributesOfItem(atPath: url.path),
                       let sizeVal2 = attrs2[.size] {
                        let size2 = (sizeVal2 as? NSNumber)?.int64Value ?? (sizeVal2 as? Int64) ?? (sizeVal2 as? UInt64).map(Int64.init) ?? 0
                        if size1 == size2 && size2 > 0 {
                            return true
                        }
                    }
                }
            }
            if attempts < maxAttempts {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return false
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
        if !pendingTargetFilenames.isEmpty {
            return true
        }

        if appGroupIDs.contains(where: {
            (UserDefaults(suiteName: $0)?.double(forKey: "pendingShareImportTimestamp") ?? 0) > 0 ||
            UserDefaults(suiteName: $0)?.bool(forKey: "hasPendingShareImport") == true
        }) {
            return true
        }

        // Sideload / Unsigned IPA Fallback Bridge: Check UIPasteboard.general for non-empty file data
        let fileTypeKey = "com.antigravity.InksyncPro.sharedFileData"
        let fileNameKey = "com.antigravity.InksyncPro.sharedFileName"
        if let pbData = UIPasteboard.general.data(forPasteboardType: fileTypeKey), !pbData.isEmpty {
            return true
        }
        if UIPasteboard.general.items.contains(where: {
            if let data = $0[fileTypeKey] as? Data, !data.isEmpty { return true }
            if ($0[fileNameKey] != nil || !self.pendingTargetFilenames.isEmpty),
               let data = $0[UTType.data.identifier] as? Data, !data.isEmpty {
                return true
            }
            return false
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

    nonisolated static func detectExtensionFromBytes(_ data: Data) -> String? {
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
