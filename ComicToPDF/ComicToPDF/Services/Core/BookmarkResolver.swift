import Foundation

// ============================================================================
// BookmarkResolver
// ============================================================================
// The single, centralized actor for ALL security-scoped bookmark resolution.
// Every component that needs to open a linked file goes through here.
// No scattered startAccessingSecurityScopedResource() calls elsewhere.
// ============================================================================

enum BookmarkError: Error, LocalizedError {
    case driveDisconnected
    case stale
    case timedOut
    case readOnly
    case resolutionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .driveDisconnected: return "The external drive is not connected."
        case .stale:             return "The drive link has expired. Please re-link the drive."
        case .timedOut:          return "The drive did not respond in time. Check the connection."
        case .readOnly:          return "This file is on a read-only drive."
        case .resolutionFailed(let e): return "Could not access drive file: \(e.localizedDescription)"
        }
    }
}

actor BookmarkResolver {

    static let shared = BookmarkResolver()
    private init() {}

    // MARK: - Public API

    /// Resolve a bookmark to a live URL that can be opened.
    /// Automatically re-bookmarks and persists stale data when detected.
    /// nonisolated so it can be called from sync contexts (e.g. compactMap closures).
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
                // Post notification so LinkedLibraryScanner can refresh the stored bookmark
                NotificationCenter.default.post(
                    name: .bookmarkBecameStale,
                    object: bookmarkData
                )
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

    /// Open a linked file, run an async operation on its resolved URL, then release access.
    /// A configurable timeout watchdog fires BookmarkError.timedOut if the drive stalls.
    func withAccess<T: Sendable>(
        _ bookmarkData: Data,
        timeout: Duration = .seconds(600),
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolvedURL = try resolve(bookmarkData)
        let accessing = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation(resolvedURL)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BookmarkError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Quick reachability probe — does NOT hold access open.
    func isReachable(_ bookmarkData: Data) async -> Bool {
        guard let url = try? resolve(bookmarkData) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Check if a drive URL allows writing (used by ArchiveMutatorService guard).
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
