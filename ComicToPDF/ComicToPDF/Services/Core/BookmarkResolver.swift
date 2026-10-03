import Foundation

// ============================================================================
// BookmarkResolver
// ============================================================================
// The single, centralized actor for ALL security-scoped bookmark resolution.
//
// iOS vs macOS Bookmark API:
//  - .withSecurityScope is macOS-ONLY and unavailable on iOS.
//  - On iOS, bookmark creation uses options: [] (no special flag needed).
//  - Resolution uses options: .withoutUI (prevents system dialogs blocking callers).
//  - startAccessingSecurityScopedResource() is still required on resolved URLs
//    to activate the security grant that the document picker established.
//
// NSFileCoordinator (learned from WWDC + Infuse patterns):
//  - Wrapping reads in NSFileCoordinator prevents silent data corruption when
//    Spotlight, the Files app, or a cloud sync daemon accesses the same file
//    concurrently on an external drive.
// ============================================================================

enum BookmarkError: Error, LocalizedError {
    case driveDisconnected
    case stale
    case timedOut
    case readOnly
    case resolutionFailed(underlying: Error)
    case coordinationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .driveDisconnected:         return "The external drive is not connected."
        case .stale:                     return "The drive link has expired. Please re-link the drive."
        case .timedOut:                  return "The drive did not respond in time. Check the connection."
        case .readOnly:                  return "This file is on a read-only drive."
        case .resolutionFailed(let e):   return "Could not access drive file: \(e.localizedDescription)"
        case .coordinationFailed(let e): return "File coordination error: \(e.localizedDescription)"
        }
    }
}

actor BookmarkResolver {

    static let shared = BookmarkResolver()
    private init() {}

    // MARK: - Public API

    /// Resolve a bookmark to a live URL.
    ///
    /// iOS bookmark resolution uses .withoutUI (NOT .withSecurityScope — that flag
    /// is macOS-only). The caller must still call startAccessingSecurityScopedResource()
    /// on the returned URL to activate the document-picker security grant.
    nonisolated func resolve(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                Logger.shared.log("BookmarkResolver: bookmark is STALE for \(url.lastPathComponent) — posting notification", category: "BookmarkResolver", type: .warning)
                Task { @MainActor in
                    NotificationCenter.default.post(name: .bookmarkBecameStale, object: bookmarkData)
                }
            }
            return url
        } catch {
            if let fallbackURL = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: bookmarkData) as? URL {
                Logger.shared.log("BookmarkResolver: Resolved fallback unarchived URL: \(fallbackURL.lastPathComponent)", category: "BookmarkResolver", type: .info)
                return fallbackURL
            }
            Logger.shared.log("BookmarkResolver: resolve FAILED: \(error.localizedDescription)", category: "BookmarkResolver", type: .error)
            throw BookmarkError.resolutionFailed(underlying: error)
        }
    }

public struct ResolvedAccess: Sendable {
    public let fileURL: URL
    public let securityScopeURL: URL?

    public init(fileURL: URL, securityScopeURL: URL? = nil) {
        self.fileURL = fileURL
        self.securityScopeURL = securityScopeURL
    }

    public func stopAccess() {
        securityScopeURL?.stopAccessingSecurityScopedResource()
    }
}

    /// Resolves guaranteed filesystem access for a ConvertedPDF, whether local sandbox,
    /// a directly linked file, or a child file inside a linked folder/drive.
    /// Returns a ResolvedAccess holding the true file URL and the security scope root to cleanup.
    nonisolated func resolveAccess(for pdf: ConvertedPDF) throws -> ResolvedAccess {
        if case .linked(let bookmarkData) = pdf.sourceMode {
            let resolved = try resolve(bookmarkData)
            let didAccess = resolved.startAccessingSecurityScopedResource()
            let scopeURL = didAccess ? resolved : nil

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
            if !exists {
                if didAccess { resolved.stopAccessingSecurityScopedResource() }
                Task { @MainActor in
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.driveDisconnected"), object: pdf)
                }
                throw BookmarkError.driveDisconnected
            }
            let isDirectory = (exists && isDir.boolValue) || resolved.hasDirectoryPath

            if isDirectory {
                // ── Folder / Volume link: locate the child file relative to the ──
                // bookmark-resolved root (which has an active security scope).
                //
                // IMPORTANT: On iOS, pdf.url retains the ORIGINAL path from when
                // the file was first linked (e.g. /private/var/mobile/.../ExFAT/Comics/Batman.cbz).
                // After a drive remount, that path may be at a new inode/mount point.
                // We MUST NOT call fileExists on pdf.url.path directly — it bypasses
                // the security scope and can return stale cached metadata.
                // Always resolve children relative to `resolved` (the scope root).
                let candidateURL: URL
                // Strategy 1: direct child by filename (most common case)
                let directChild = resolved.appendingPathComponent(pdf.url.lastPathComponent)
                if FileManager.default.fileExists(atPath: directChild.path) {
                    candidateURL = directChild
                } else {
                    // Strategy 2: reconstruct relative subpath from pdf.url components
                    // by finding the first path component that matches the resolved root name.
                    let rootName = resolved.lastPathComponent
                    let components = pdf.url.pathComponents
                    if let rootIdx = components.lastIndex(of: rootName), rootIdx + 1 < components.count {
                        let subpath = components[(rootIdx + 1)...].joined(separator: "/")
                        let subURL = resolved.appendingPathComponent(subpath)
                        candidateURL = FileManager.default.fileExists(atPath: subURL.path) ? subURL : directChild
                    } else {
                        // Strategy 3: deep search by filename within one level (handles
                        // drives that shuffle subdirectory structure between mounts).
                        let filename = pdf.url.lastPathComponent
                        let fm = FileManager.default
                        if let contents = try? fm.contentsOfDirectory(
                            at: resolved,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            // Check immediate subfolders (one level deep) for the file
                            let found = contents.first { child in
                                if let rv = try? child.resourceValues(forKeys: [.isDirectoryKey]), rv.isDirectory == true {
                                    let nested = child.appendingPathComponent(filename)
                                    return FileManager.default.fileExists(atPath: nested.path)
                                }
                                return child.lastPathComponent == filename
                            }
                            if let found {
                                let nestedCandidate = found.appendingPathComponent(filename)
                                candidateURL = FileManager.default.fileExists(atPath: nestedCandidate.path)
                                    ? nestedCandidate : found
                            } else {
                                candidateURL = directChild
                            }
                        } else {
                            candidateURL = directChild
                        }
                    }
                }
                return ResolvedAccess(fileURL: candidateURL, securityScopeURL: scopeURL)
            } else {
                // Direct single file link
                return ResolvedAccess(fileURL: resolved, securityScopeURL: scopeURL)
            }
        }

        // Local sandbox document
        let localURL = LibraryFileRecord.resolveSandboxURL(pdf.url.absoluteString)
        return ResolvedAccess(fileURL: localURL, securityScopeURL: nil)
    }

    /// Resolves access with an explicit timeout race to defend against hung I/O when
    /// an external drive or network share is disconnected mid-access.
    nonisolated func resolveAccessWithTimeout(for pdf: ConvertedPDF, timeoutSeconds: Double = 2.5) async throws -> ResolvedAccess {
        try await withThrowingTaskGroup(of: ResolvedAccess.self) { group in
            group.addTask {
                try self.resolveAccess(for: pdf)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw BookmarkError.driveDisconnected
            }
            guard let firstResult = try await group.next() else {
                throw BookmarkError.driveDisconnected
            }
            group.cancelAll()
            return firstResult
        }
    }

    /// Resolve a linked ConvertedPDF's URL, or return its url directly if local.
    nonisolated func resolveIfLinked(_ pdf: borrowing ConvertedPDF) throws -> URL {
        let access = try resolveAccess(for: copy pdf)
        return access.fileURL
    }

    // MARK: - Coordinated Access

    /// Open a linked file, acquire security scope, wrap the operation in NSFileCoordinator,
    /// then release access. This is the safest way to read from external drives on iOS.
    ///
    /// NSFileCoordinator prevents data corruption when Spotlight, the Files app, or any
    /// other process is simultaneously accessing the same external drive file.
    func withAccess<T: Sendable>(
        _ bookmarkData: Data,
        timeout: Duration = .seconds(600),
        operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolvedURL = try resolve(bookmarkData)
        let accessing = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let holder = CoordinatedResultHolder<T>()
                var coordinationError: NSError?
                var didExecute = false

                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: resolvedURL, options: [], error: &coordinationError) { safeURL in
                    didExecute = true
                    let semaphore = DispatchSemaphore(value: 0)
                    let operationTask = Task {
                        return try await operation(safeURL)
                    }
                    
                    let watchdog = Task {
                        try? await Task.sleep(for: timeout)
                        operationTask.cancel()
                    }
                    
                    Task {
                        do {
                            holder.result = try await operationTask.value
                        } catch {
                            holder.error = error
                        }
                        watchdog.cancel()
                        semaphore.signal()
                    }
                    
                    let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    _ = semaphore.wait(timeout: .now() + timeoutSeconds)
                    
                    if let opError = holder.error {
                        continuation.resume(throwing: opError)
                    } else if let finalResult = holder.result {
                        continuation.resume(returning: finalResult)
                    } else {
                        Logger.shared.log("BookmarkResolver.withAccess: operation TIMED OUT after \(timeout)", category: "BookmarkResolver", type: .error)
                        continuation.resume(throwing: BookmarkError.timedOut)
                    }
                }

                if let coordError = coordinationError {
                    continuation.resume(throwing: BookmarkError.coordinationFailed(underlying: coordError))
                } else if !didExecute {
                    continuation.resume(throwing: BookmarkError.coordinationFailed(underlying: NSError(domain: "BookmarkResolver", code: -1, userInfo: [NSLocalizedDescriptionKey: "NSFileCoordinator failed to execute block silently."])))
                }
            }
        }
    }

    /// Coordinated write access — use for any mutation on external drive files.
    func withWriteAccess<T: Sendable>(
        _ bookmarkData: Data,
        timeout: Duration = .seconds(600),
        operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolvedURL = try resolve(bookmarkData)
        let accessing = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let holder = CoordinatedResultHolder<T>()
                var coordinationError: NSError?
                var didExecute = false

                let coordinator = NSFileCoordinator()
                coordinator.coordinate(writingItemAt: resolvedURL, options: .forReplacing, error: &coordinationError) { safeURL in
                    didExecute = true
                    let semaphore = DispatchSemaphore(value: 0)
                    let operationTask = Task {
                        return try await operation(safeURL)
                    }
                    
                    let watchdog = Task {
                        try? await Task.sleep(for: timeout)
                        operationTask.cancel()
                    }
                    
                    Task {
                        do {
                            holder.result = try await operationTask.value
                        } catch {
                            holder.error = error
                        }
                        watchdog.cancel()
                        semaphore.signal()
                    }
                    
                    let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    _ = semaphore.wait(timeout: .now() + timeoutSeconds)
                    
                    if let opError = holder.error {
                        continuation.resume(throwing: opError)
                    } else if let finalResult = holder.result {
                        continuation.resume(returning: finalResult)
                    } else {
                        Logger.shared.log("BookmarkResolver.withWriteAccess: write operation TIMED OUT after \(timeout)", category: "BookmarkResolver", type: .error)
                        continuation.resume(throwing: BookmarkError.timedOut)
                    }
                }

                if let coordError = coordinationError {
                    continuation.resume(throwing: BookmarkError.coordinationFailed(underlying: coordError))
                } else if !didExecute {
                    continuation.resume(throwing: BookmarkError.coordinationFailed(underlying: NSError(domain: "BookmarkResolver", code: -1, userInfo: [NSLocalizedDescriptionKey: "NSFileCoordinator failed to execute block silently."])))
                }
            }
        }
    }

    // MARK: - Reachability

    /// Quick reachability probe using NSFileCoordinator to prevent false positives
    /// from cached filesystem metadata on disconnected drives.
    func isReachable(_ bookmarkData: Data) async -> Bool {
        guard let url = try? resolve(bookmarkData) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Use NSFileCoordinator with .immediatelyAvailableMetadataOnly to bypass
        // the kernel's stale inode cache. fileExists() can return true for a
        // physically disconnected drive whose metadata is still cached in VFS.
        var coordError: NSError?
        var isReachable = false
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly, error: &coordError) { safeURL in
            var resourceValues: URLResourceValues?
            var attemptError: Error?
            do {
                resourceValues = try safeURL.resourceValues(forKeys: [.isReadableKey])
            } catch {
                attemptError = error
            }
            isReachable = (attemptError == nil) && (resourceValues?.isReadable == true)
        }

        return coordError == nil && isReachable
    }

    /// Check if a drive URL allows writing.
    func checkWritable(_ bookmarkData: Data) async -> Bool {
        guard let url = try? resolve(bookmarkData) else {
            Logger.shared.log("BookmarkResolver.checkWritable: could not resolve bookmark", category: "BookmarkResolver", type: .warning)
            return false
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let writable = FileManager.default.isWritableFile(atPath: url.path)
        if !writable {
            Logger.shared.log("BookmarkResolver.checkWritable: drive is READ-ONLY at \(url.lastPathComponent)", category: "BookmarkResolver", type: .warning)
        }
        return writable
    }
}

private final class CoordinatedResultHolder<T>: @unchecked Sendable {
    var result: T?
    var error: Error?
}

// MARK: - Notification Names

extension Notification.Name {
    static let bookmarkBecameStale      = Notification.Name("InksyncPro.bookmarkBecameStale")
    static let linkedDriveConnected     = Notification.Name("InksyncPro.linkedDriveConnected")
    static let linkedDriveDisconnected  = Notification.Name("InksyncPro.linkedDriveDisconnected")
    /// Posted by CloudCoverExtractor when a cloud cover is written to disk.
    /// userInfo["pdfID"] = UUID, userInfo["image"] = UIImage
    static let cloudCoverReady          = Notification.Name("InksyncPro.cloudCoverReady")
}
