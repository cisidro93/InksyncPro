import Foundation

// ============================================================================
// BookmarkResolver
// ============================================================================
// The single, centralized actor for ALL security-scoped bookmark resolution.
// Every component that needs to open a linked file goes through here.
//
// Key improvements learned from Infuse / Apple WWDC patterns:
//  - All reads/writes through external-drive URLs are wrapped in NSFileCoordinator.
//    Without coordination, concurrent access from Spotlight, the Files app, or a
//    background sync daemon can silently corrupt reads (truncated data, partial writes).
//  - Bookmark creation always uses .withSecurityScope so the resolved URL remains
//    valid across app restarts without re-prompting the user.
//  - The .withoutUI option on resolution prevents iOS from displaying its own dialog
//    boxes, which would block the caller in unexpected places.
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
    /// Uses .withSecurityScope so the resolved URL is usable AFTER the picker session ends.
    /// Emits .bookmarkBecameStale notification when iOS reports the bookmark as stale.
    nonisolated func resolve(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .bookmarkBecameStale, object: bookmarkData)
                }
            }
            return url
        } catch {
            // Fallback: try without security scope (cloud providers that manage their own tokens)
            if let fallbackURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .bookmarkBecameStale, object: bookmarkData)
                    }
                }
                return fallbackURL
            }
            throw BookmarkError.resolutionFailed(underlying: error)
        }
    }

    /// Resolve a linked ConvertedPDF's URL, or return its url directly if local.
    func resolveIfLinked(_ pdf: borrowing ConvertedPDF) throws -> URL {
        if case .linked(let bm) = pdf.sourceMode {
            return try resolve(bm)
        }
        return pdf.url
    }

    // MARK: - Coordinated Access (the Infuse/WWDC-recommended pattern)

    /// Open a linked file, acquire security scope, wrap the operation in NSFileCoordinator,
    /// then release access. This is the ONLY safe way to read from external drives.
    ///
    /// NSFileCoordinator prevents data corruption when Spotlight, the Files app, or any
    /// other process is simultaneously accessing the same external drive file.
    ///
    /// The timeout watchdog cancels the operation if the drive stalls past the deadline.
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

        // NSFileCoordinator: wrap the entire operation so the system can safely
        // coordinate concurrent access from other processes (Spotlight, Files app).
        var coordinationError: NSError?
        var coordinatedURL: URL = resolvedURL

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: resolvedURL, options: [], error: &coordinationError) { safeURL in
            coordinatedURL = safeURL
        }
        if let coordError = coordinationError {
            throw BookmarkError.coordinationFailed(underlying: coordError)
        }

        let operationTask = Task { try await operation(coordinatedURL) }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            operationTask.cancel()
        }

        do {
            let result = try await operationTask.value
            watchdog.cancel()
            return result
        } catch is CancellationError {
            watchdog.cancel()
            throw BookmarkError.timedOut
        } catch {
            watchdog.cancel()
            throw error
        }
    }

    /// Coordinated write access — use this for any mutation on external drive files.
    /// Without coordination, a write from Inksync can collide with a Files app sync,
    /// producing a corrupted file on the drive.
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

        var coordinationError: NSError?
        var coordinatedURL: URL = resolvedURL

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: resolvedURL, options: .forReplacing, error: &coordinationError) { safeURL in
            coordinatedURL = safeURL
        }
        if let coordError = coordinationError {
            throw BookmarkError.coordinationFailed(underlying: coordError)
        }

        let operationTask = Task { try await operation(coordinatedURL) }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            operationTask.cancel()
        }

        do {
            let result = try await operationTask.value
            watchdog.cancel()
            return result
        } catch is CancellationError {
            watchdog.cancel()
            throw BookmarkError.timedOut
        } catch {
            watchdog.cancel()
            throw error
        }
    }

    // MARK: - Reachability

    /// Quick reachability probe using NSFileCoordinator to prevent false positives
    /// from cached filesystem metadata on disconnected drives.
    func isReachable(_ bookmarkData: Data) async -> Bool {
        guard let url = try? resolve(bookmarkData) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Use NSFileCoordinator to bypass the kernel's inode metadata cache.
        // Without coordination, fileExists() can return true for a disconnected
        // drive because the metadata is cached in the kernel's VFS layer.
        var coordError: NSError?
        var isReachable = false
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly, error: &coordError) { safeURL in
            // .immediatelyAvailableMetadataOnly tells the coordinator not to wait
            // for a network drive to spin up — if the metadata isn't immediately
            // available, it won't block. For USB drives, this resolves instantly.
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
        guard let url = try? resolve(bookmarkData) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let bookmarkBecameStale      = Notification.Name("InksyncPro.bookmarkBecameStale")
    static let linkedDriveConnected     = Notification.Name("InksyncPro.linkedDriveConnected")
    static let linkedDriveDisconnected  = Notification.Name("InksyncPro.linkedDriveDisconnected")
}
