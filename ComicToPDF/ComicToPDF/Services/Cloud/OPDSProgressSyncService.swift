import Foundation

// MARK: - OPDS Progress Sync Service

/// Actor responsible for reading and writing per-book reading progress to
/// Kavita and Komga via their native REST APIs.
///
/// This is intentionally separate from OPDSClient (OPDS browsing) because
/// progress sync is NOT part of the OPDS standard — it requires server-specific
/// REST calls authenticated with the same credentials already in Keychain.
///
/// Fire-and-forget pattern: saveProgress never throws to the caller.
/// All errors are logged and silently swallowed to avoid disrupting the reading UX.
actor OPDSProgressSyncService {

    static let shared = OPDSProgressSyncService()

    // MARK: - Public API

    /// Saves the current reading position to the server.
    /// Call every 5 page turns, on reader dismiss, and on scene background.
    /// Never throws — errors are logged and ignored.
    func saveProgress(server: SDOPDSServer, entry: OPDSEntry, page: Int, completed: Bool = false) async {
        do {
            switch server.serverType {
            case .kavita:
                try await kavitaProgress(server: server, entry: entry, page: page)
            case .komga:
                try await komgaProgress(server: server, entry: entry, page: page, completed: completed)
            case .calibre:
                return  // Calibre has no progress API — Phase 3 (Wireless Device protocol)
            }
            Logger.shared.log(
                "OPDSProgressSync: saved page \(page) for '\(entry.title)' on \(server.serverType.rawValue)",
                category: "OPDS"
            )
        } catch {
            Logger.shared.log(
                "OPDSProgressSync: failed to save progress for '\(entry.title)' — \(error.localizedDescription)",
                category: "OPDS",
                type: .warning
            )
        }
    }

    /// Loads the last-read page from the server for resume-on-open.
    /// Returns nil for Calibre or if the server has no record.
    func loadProgress(server: SDOPDSServer, entry: OPDSEntry) async -> Int? {
        // Fast path: PSE feed already carried pse:lastRead
        if let lastRead = entry.pseLastRead { return lastRead }

        do {
            switch server.serverType {
            case .kavita:
                return try await kavitaGetProgress(server: server, entry: entry)
            case .komga:
                return try await komgaGetProgress(server: server, entry: entry)
            case .calibre:
                return nil
            }
        } catch {
            Logger.shared.log(
                "OPDSProgressSync: failed to load progress for '\(entry.title)' — \(error.localizedDescription)",
                category: "OPDS",
                type: .warning
            )
            return nil
        }
    }

    // MARK: - Kavita

    /// POST /api/Reader/progress
    /// Body: { chapterId, volumeId, pageNum, seriesId, libraryId } — ALL required
    private func kavitaProgress(server: SDOPDSServer, entry: OPDSEntry, page: Int) async throws {
        guard let chapterId = entry.kavitaChapterId,
              let volumeId  = entry.kavitaVolumeId,
              let seriesId  = entry.kavitaSeriesId
        else {
            Logger.shared.log(
                "OPDSProgressSync: Kavita IDs missing for '\(entry.title)' — skipping sync",
                category: "OPDS",
                type: .warning
            )
            return
        }

        guard let base = server.baseURL else { throw OPDSError.invalidURL }
        let url = base.appendingPathComponent("api/Reader/progress")

        var body: [String: Any] = [
            "chapterId": chapterId,
            "volumeId":  volumeId,
            "pageNum":   page,
            "seriesId":  seriesId,
        ]
        // libraryId is required by Kavita; if we don't have it, default to 0
        // (Kavita will reject entries with wrong libraryId — progress simply won't save)
        body["libraryId"] = entry.kavitaLibraryId ?? 0

        let request = try authRequest(url: url, method: "POST", body: body, server: server)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OPDSError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// GET /api/Reader/get-progress?chapterId={id}
    private func kavitaGetProgress(server: SDOPDSServer, entry: OPDSEntry) async throws -> Int? {
        guard let chapterId = entry.kavitaChapterId,
              let base = server.baseURL else { return nil }

        var comps = URLComponents(url: base.appendingPathComponent("api/Reader/get-progress"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "chapterId", value: "\(chapterId)")]
        guard let url = comps.url else { return nil }

        let request = try authRequest(url: url, method: "GET", body: nil, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageNum = json["pageNum"] as? Int
        else { return nil }

        return pageNum
    }

    // MARK: - Komga

    /// PATCH /api/v1/books/{bookId}/read-progress
    /// Body: { page: Int, completed: Bool }
    private func komgaProgress(server: SDOPDSServer, entry: OPDSEntry, page: Int, completed: Bool) async throws {
        guard let bookId = entry.komgaBookId,
              let base = server.baseURL else {
            Logger.shared.log(
                "OPDSProgressSync: Komga bookId missing for '\(entry.title)' — skipping sync",
                category: "OPDS",
                type: .warning
            )
            return
        }

        let url = base.appendingPathComponent("api/v1/books/\(bookId)/read-progress")
        let body: [String: Any] = ["page": page, "completed": completed]
        let request = try authRequest(url: url, method: "PATCH", body: body, server: server)
        let (_, response) = try await URLSession.shared.data(for: request)
        // Komga returns 204 No Content on success
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 204 || (200...299).contains(http.statusCode)
        else {
            throw OPDSError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// GET /api/v1/books/{bookId} → readProgress.page
    private func komgaGetProgress(server: SDOPDSServer, entry: OPDSEntry) async throws -> Int? {
        guard let bookId = entry.komgaBookId,
              let base = server.baseURL else { return nil }

        let url = base.appendingPathComponent("api/v1/books/\(bookId)")
        let request = try authRequest(url: url, method: "GET", body: nil, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let readProgress = json["readProgress"] as? [String: Any],
              let page = readProgress["page"] as? Int
        else { return nil }

        return page
    }

    // MARK: - Shared Auth Request Builder

    private func authRequest(url: URL, method: String, body: [String: Any]?, server: SDOPDSServer) throws -> URLRequest {
        let credential = OPDSKeychainStore.load(for: server.id)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        if server.serverType == .kavita {
            if let token = credential?.bearerToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        } else {
            if let cred = credential, !cred.username.isEmpty {
                let raw = "\(cred.username):\(cred.password)"
                if let data = raw.data(using: .utf8) {
                    request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
            }
        }
        return request
    }
}
