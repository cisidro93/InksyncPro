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
            // ✅ iOS CORRECT: options: .withoutUI — prevents system UI dialogs.
            // Do NOT use .withSecurityScope — that is macOS App Sandbox only.
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
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
