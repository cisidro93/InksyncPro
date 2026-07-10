import Foundation

// MARK: - Feed Models

/// Represents the two kinds of OPDS feed entries:
/// - `.navigation` — a catalog link to drill into (series, libraries, etc.)
/// - `.acquisition` — an actual book with download / stream URLs
enum OPDSEntryKind {
    case navigation
    case acquisition
}

struct OPDSNavLink: Identifiable {
    let id: String
    let title: String
    let feedURL: URL
}

struct OPDSEntry: Identifiable {
    let id: String
    let title: String
    let author: String
    let coverURL: URL?
    let downloadURL: URL?
    let streamURL: URL?   // OPDS-PSE (Page Streaming Extension) — Kavita / Komga
    let pageCount: Int?   // nil = not reported by server
    let kind: OPDSEntryKind

    // Phase 2: Server-native IDs for REST progress sync
    // Kavita — extracted from OPDS link href path: /series/{s}/volume/{v}/chapter/{c}
    let kavitaChapterId: Int?
    let kavitaVolumeId: Int?
    let kavitaSeriesId: Int?
    let kavitaLibraryId: Int?   // parsed from library-level nav feed href

    // Komga — extracted from href: /books/{bookId}/...
    let komgaBookId: String?    // alphanumeric string e.g. "03KMX9PBZTVMP"

    // PSE — pse:lastRead attribute on the <link pse:stream> element
    let pseLastRead: Int?       // 0-based page index of last read position

    // Phase 3: Divina / Readium WebPub readingOrder page URLs (Komga OPDS 2.0)
    // Pre-resolved absolute URLs for each page image, in reading order.
    // nil for all PSE/download-only entries.
    let divinaPageURLs: [URL]?  // count == totalPages when non-nil
}

struct OPDSFeed {
    let title: String
    let entries: [OPDSEntry]
    let navLinks: [OPDSNavLink]
    let searchURL: URL?    // OpenSearch descriptor URL, if the server exposes one
    let nextPageURL: URL?  // Pagination: rel="next" link
}

// MARK: - XML Parser

/// SAX parser for OPDS Atom feeds.
/// Handles both navigation feeds (catalog drill-down) and acquisition feeds (book lists).
final class OPDSFeedParser: NSObject, XMLParserDelegate {

    // Feed-level state
    private var feedTitle: String = ""
    private var feedSearchURL: URL?
    private var feedNextPageURL: URL?

    // Entry accumulation
    private var entries: [OPDSEntry] = []
    private var navLinks: [OPDSNavLink] = []

    // Entry parse state
    private var insideEntry = false
    private var entryID = ""
    private var entryTitle = ""
    private var entryAuthor = ""
    private var entryCoverURL: URL?
    private var entryDownloadURL: URL?
    private var entryStreamURL: URL?
    private var entryPageCount: Int?
    private var entryIsNavigation = false
    private var entryNavFeedURL: URL?

    // Phase 2: ID extraction state
    private var entryKavitaChapterId: Int?
    private var entryKavitaVolumeId: Int?
    private var entryKavitaSeriesId: Int?
    private var entryKavitaLibraryId: Int?
    private var entryKomgaBookId: String?
    private var entryPseLastRead: Int?

    // Character accumulation
    private var currentElement = ""
    private var charBuf = ""

    // MARK: - Public API

    func parse(data: Data) -> OPDSFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        return OPDSFeed(
            title:       feedTitle.trimmed,
            entries:     entries,
            navLinks:    navLinks,
            searchURL:   feedSearchURL,
            nextPageURL: feedNextPageURL
        )
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attrs: [String: String] = [:]) {

        let localName = qName ?? elementName
        currentElement = localName
        charBuf = ""

        switch localName {
        case "entry":
            insideEntry          = true
            entryID              = ""
            entryTitle           = ""
            entryAuthor          = ""
            entryCoverURL        = nil
            entryDownloadURL     = nil
            entryStreamURL       = nil
            entryPageCount       = nil
            entryIsNavigation    = false
            entryNavFeedURL      = nil
            entryKavitaChapterId = nil
            entryKavitaVolumeId  = nil
            entryKavitaSeriesId  = nil
            entryKavitaLibraryId = nil
            entryKomgaBookId     = nil
            entryPseLastRead     = nil

        case "link":
            handleLink(attrs: attrs)

        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        charBuf += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {

        let text = charBuf.trimmed
        let localName = qName ?? elementName

        if !insideEntry {
            // Feed-level elements
            if localName == "title" && feedTitle.isEmpty {
                feedTitle = text
            }
        } else {
            // Entry-level elements
            switch localName {
            case "id":
                if entryID.isEmpty { entryID = text }
            case "title":
                if entryTitle.isEmpty { entryTitle = text }
            case "name":
                // <author><name>…</name></author>
                if entryAuthor.isEmpty { entryAuthor = text }
            case "dcterms:extent", "extent",
                 "schema:numberOfPages", "numberOfPages":
                let cleaned = text
                    .replacingOccurrences(of: " pages", with: "")
                    .replacingOccurrences(of: " page", with: "")
                if let count = Int(cleaned), count > 0 {
                    entryPageCount = count
                }
            case "entry":
                commitEntry()
                insideEntry = false
            default: break
            }
        }
        currentElement = ""
        charBuf = ""
    }

    // MARK: - Private Helpers

    private func handleLink(attrs: [String: String]) {
        guard let rel  = attrs["rel"],
              let href = attrs["href"]
        else { return }

        let type = attrs["type"] ?? ""

        if !insideEntry {
            // Feed-level links
            if rel == "search" || type.contains("opensearch") {
                feedSearchURL = resolvedURL(href)
            } else if rel == "next" {
                feedNextPageURL = resolvedURL(href)
            }
            return
        }

        // Entry-level links
        let url = resolvedURL(href)

        if rel.contains("opds-spec.org/image") || rel == "thumbnail" ||
           rel.contains("image/") {
            entryCoverURL = url

        } else if rel.contains("opds-spec.org/acquisition") {
            // Acquisition link — this is a downloadable book
            entryDownloadURL = url
            entryIsNavigation = false
            // Extract server-native IDs from the href for Phase 2 progress sync
            extractServerIDs(from: href)

        } else if rel.contains("vaemendis.net/opds-pse/stream") ||
                  rel.contains("opds-pse") {
            // OPDS-PSE page streaming (Kavita / Komga)
            entryStreamURL = url
            // pse:lastRead attribute carries the resume position
            if let lastRead = attrs["pse:lastRead"] ?? attrs["lastRead"],
               let page = Int(lastRead) {
                entryPseLastRead = page
            }
            // Also extract IDs if present in the PSE stream href
            if entryKavitaChapterId == nil { extractServerIDs(from: href) }

        } else if rel == "subsection" || rel == "http://opds-spec.org/subsection" {
            // Navigation feed — drill-down catalog link
            entryIsNavigation = true
            entryNavFeedURL = url
        }
    }

    // MARK: - Server ID Extraction

    /// Parses Kavita and Komga native IDs from an OPDS link href.
    /// Kavita:  /api/opds/.../series/{seriesId}/volume/{volumeId}/chapter/{chapterId}
    /// Komga:   /opds/v1.2/books/{bookId}/...
    private func extractServerIDs(from href: String) {
        // Kavita — integer path segments
        if let seriesId = regexInt(href, pattern: "/series/(\\d+)") {
            entryKavitaSeriesId = seriesId
        }
        if let volumeId = regexInt(href, pattern: "/volume/(\\d+)") {
            entryKavitaVolumeId = volumeId
        }
        if let chapterId = regexInt(href, pattern: "/chapter/(\\d+)") {
            entryKavitaChapterId = chapterId
        }
        if let libraryId = regexInt(href, pattern: "/library/(\\d+)") {
            entryKavitaLibraryId = libraryId
        }

        // Komga — alphanumeric book ID
        if let match = href.range(of: #"/books/([A-Z0-9]+)"#, options: .regularExpression) {
            let segment = String(href[match])
            let bookId = segment.replacingOccurrences(of: "/books/", with: "")
            if !bookId.isEmpty { entryKomgaBookId = bookId }
        }
    }

    private func regexInt(_ string: String, pattern: String) -> Int? {
        guard let range = string.range(of: pattern, options: .regularExpression),
              let numRange = string[range].range(of: #"\d+"#, options: .regularExpression)
        else { return nil }
        return Int(string[range][numRange])
    }


    private func commitEntry() {
        if entryIsNavigation, let feedURL = entryNavFeedURL {
            navLinks.append(OPDSNavLink(
                id:      entryID.isEmpty ? UUID().uuidString : entryID,
                title:   entryTitle,
                feedURL: feedURL
            ))
        } else {
            entries.append(OPDSEntry(
                id:               entryID.isEmpty ? UUID().uuidString : entryID,
                title:            entryTitle,
                author:           entryAuthor,
                coverURL:         entryCoverURL,
                downloadURL:      entryDownloadURL,
                streamURL:        entryStreamURL,
                pageCount:        entryPageCount,
                kind:             entryIsNavigation ? .navigation : .acquisition,
                kavitaChapterId:  entryKavitaChapterId,
                kavitaVolumeId:   entryKavitaVolumeId,
                kavitaSeriesId:   entryKavitaSeriesId,
                kavitaLibraryId:  entryKavitaLibraryId,
                komgaBookId:      entryKomgaBookId,
                pseLastRead:      entryPseLastRead,
                divinaPageURLs:   nil   // Atom XML feeds never have Divina readingOrder
            ))
        }
    }

    /// Resolves a potentially relative href against the feed's base URL.
    /// Since we don't have the base URL at parse time, relative hrefs are returned as-is
    /// and the caller is responsible for resolution if needed.
    private func resolvedURL(_ href: String) -> URL? {
        URL(string: href)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - OPDS Client

/// `actor` ensures all async network calls are isolated without data races.
@MainActor final class OPDSClient: Sendable {

    static let shared = OPDSClient()

    // MARK: - Fetch Feed

    /// Fetches and parses an OPDS feed at the given URL on `server`.
    /// Auto-detects OPDS 2.0 (application/opds+json) vs Atom XML and
    /// routes to the correct parser. The output model is always OPDSFeed.
    func fetchFeed(server: SDOPDSServer, url: URL? = nil) async throws -> OPDSFeed {
        let credential = OPDSKeychainStore.load(for: server.id)

        // Determine target URL
        let targetURL: URL
        if let explicit = url {
            targetURL = explicit
        } else if let rootURL = server.opdsRootURL(credential: credential) {
            targetURL = rootURL
        } else {
            throw OPDSError.invalidURL
        }

        let (data, response) = try await fetchDataWithResponse(url: targetURL, credential: credential, server: server)
        let feed = try parseFeed(data: data, response: response, baseURL: targetURL)
        Logger.shared.log(
            "OPDSClient: fetched feed '\(feed.title)' (\(feed.entries.count) entries, \(feed.navLinks.count) nav) [\(contentTypeLabel(response))]",
            category: "OPDS"
        )
        return feed
    }

    // MARK: - Search

    /// Searches the server's catalog using the OpenSearch descriptor exposed in the root feed.
    /// Falls back to appending `?query=` if no OpenSearch descriptor is present.
    func search(server: SDOPDSServer, query: String, searchURL: URL) async throws -> OPDSFeed {
        let credential = OPDSKeychainStore.load(for: server.id)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // Replace OpenSearch {searchTerms} template, or append as ?query=
        var urlString = searchURL.absoluteString
        if urlString.contains("{searchTerms}") {
            urlString = urlString.replacingOccurrences(of: "{searchTerms}", with: encoded)
        } else {
            urlString += (urlString.contains("?") ? "&" : "?") + "query=\(encoded)"
        }
        guard let url = URL(string: urlString) else { throw OPDSError.invalidURL }

        let (data, response) = try await fetchDataWithResponse(url: url, credential: credential, server: server)
        return try parseFeed(data: data, response: response, baseURL: url)
    }

    // MARK: - Feed Parsing (Format Auto-Detection)

    /// Routes to OPDSFeedParser (Atom XML) or OPDS20FeedParser (JSON)
    /// based on the HTTP response Content-Type header.
    private func parseFeed(data: Data, response: URLResponse, baseURL: URL) throws -> OPDSFeed {
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("application/opds+json") ||
           contentType.contains("application/opds-publication+json") ||
           contentType.contains("application/webpub+json") ||
           contentType.contains("application/divina+json") {
            // OPDS 2.0 / Readium WebPub / Divina — JSON feed
            guard let feed = OPDS20FeedParser().parse(data: data, baseURL: baseURL) else {
                throw OPDSError.parseFailure
            }
            return feed
        }

        // Fallback: Atom XML (OPDS 1.x — Kavita, Komga v1, Calibre-web)
        // Also handles servers that return the wrong Content-Type for JSON
        if let feed = OPDSFeedParser().parse(data: data) { return feed }

        // Last resort: try JSON if XML failed
        if let feed = OPDS20FeedParser().parse(data: data, baseURL: baseURL) { return feed }

        throw OPDSError.parseFailure
    }

    private func contentTypeLabel(_ response: URLResponse) -> String {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            .flatMap { $0.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) }
            ?? "unknown"
    }


    // MARK: - Download Entry

    /// Downloads the file referenced by `entry.downloadURL`, saves it to a temp file,
    /// and imports it into the library via `ConversionManager.processImportedFiles`.
    func downloadEntry(
        _ entry: OPDSEntry,
        server: SDOPDSServer,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard let downloadURL = entry.downloadURL else { throw OPDSError.noDownloadURL }

        let credential = OPDSKeychainStore.load(for: server.id)
        var request = buildRequest(url: downloadURL, credential: credential, server: server)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        Logger.shared.log("OPDSClient: downloading '\(entry.title)' from \(downloadURL)", category: "OPDS")

        // Use a download task so we can stream bytes to disk without buffering in RAM
        let (localURL, response) = try await URLSession.shared.download(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OPDSError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Move from the ephemeral temp location to a named temp file
        let ext = downloadURL.pathExtension.isEmpty ? "cbz" : downloadURL.pathExtension
        let safe = entry.title
            .components(separatedBy: .init(charactersIn: "/:*?\"<>|\\"))
            .joined(separator: "_")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: localURL, to: dest)

        Logger.shared.log("OPDSClient: download complete → \(dest.lastPathComponent)", category: "OPDS")
        return dest
    }

    // MARK: - Kavita JWT Authentication

    /// Exchanges Kavita email + password for a JWT access token.
    /// Stores the bearer token and refresh token in Keychain.
    /// The plain-text password is NOT stored after this point.
    @discardableResult
    func kavitaLogin(server: SDOPDSServer, email: String, password: String) async throws -> String {
        guard let base = server.baseURL else { throw OPDSError.invalidURL }
        let loginURL = base.appendingPathComponent("api/Account/login")

        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body = ["username": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OPDSError.connectionFailed("No response") }

        if http.statusCode == 401 { throw OPDSError.connectionFailed("Invalid email or password.") }
        guard (200...299).contains(http.statusCode) else { throw OPDSError.httpError(http.statusCode) }

        let jsonObj = try? JSONSerialization.jsonObject(with: data)
        guard let json = jsonObj as? [String: Any],
              let token = json["token"] as? String
        else { throw OPDSError.parseFailure }

        let refreshToken = json["refreshToken"] as? String ?? ""

        // Store JWT in Keychain. Username (email) is kept; login password is dropped.
        let credential = OPDSCredential(
            username: email,
            password: "",            // plain password never stored
            bearerToken: token,
            refreshToken: refreshToken.isEmpty ? nil : refreshToken
        )
        OPDSKeychainStore.save(credential, for: server.id)
        Logger.shared.log("OPDSClient: Kavita JWT acquired for \(server.name)", category: "OPDS")
        return token
    }

    /// Silently refreshes a Kavita JWT using the stored refresh token.
    /// Called automatically on 401 during `fetchData`. Returns new bearer token on success.
    func refreshKavitaToken(server: SDOPDSServer) async throws -> String {
        guard var credential = OPDSKeychainStore.load(for: server.id),
              let refresh = credential.refreshToken,
              let base = server.baseURL
        else { throw OPDSError.connectionFailed("No refresh token — please re-authenticate.") }

        let url = base.appendingPathComponent("api/Account/refreshToken")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": refresh])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { throw OPDSError.connectionFailed("Token refresh failed — please re-authenticate.") }
        let refreshJsonObj = try? JSONSerialization.jsonObject(with: data)
        guard let json = refreshJsonObj as? [String: Any],
              let newToken = json["token"] as? String
        else { throw OPDSError.connectionFailed("Token refresh failed — please re-authenticate.") }

        credential.bearerToken = newToken
        if let newRefresh = json["refreshToken"] as? String { credential.refreshToken = newRefresh }
        OPDSKeychainStore.save(credential, for: server.id)
        Logger.shared.log("OPDSClient: Kavita JWT refreshed for \(server.name)", category: "OPDS")
        return newToken
    }

    // MARK: - Test Connection

    /// Attempts to fetch the root feed and returns the server's catalog title on success.
    /// For Kavita: performs the full JWT login flow using the provided credentials.
    func testConnection(server: SDOPDSServer, email: String? = nil, password: String? = nil) async throws -> String {
        // Kavita needs a login exchange before we can fetch the feed
        if server.serverType == .kavita, let email = email, let password = password, !password.isEmpty {
            try await kavitaLogin(server: server, email: email, password: password)
        }
        let feed = try await fetchFeed(server: server)
        return feed.title.isEmpty ? server.name : feed.title
    }

    // MARK: - Private

    /// Returns both the response data and the URLResponse for Content-Type inspection.
    private func fetchDataWithResponse(url: URL, credential: OPDSCredential?, server: SDOPDSServer) async throws -> (Data, URLResponse) {
        var request = buildRequest(url: url, credential: credential, server: server)
        var (data, response) = try await URLSession.shared.data(for: request)

        // On 401: attempt silent token refresh (Kavita JWT expiry) then retry once
        if let http = response as? HTTPURLResponse, http.statusCode == 401,
           server.serverType == .kavita {
            Logger.shared.log("OPDSClient: 401 on \(url.lastPathComponent) — attempting token refresh", category: "OPDS")
            let newToken = try await refreshKavitaToken(server: server)
            var retryCredential = credential ?? OPDSCredential(username: "", password: "")
            retryCredential.bearerToken = newToken
            request = buildRequest(url: url, credential: retryCredential, server: server)
            (data, response) = try await URLSession.shared.data(for: request)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OPDSError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (data, response)
    }

    /// Convenience wrapper that discards the response (legacy internal callers).
    private func fetchData(url: URL, credential: OPDSCredential?, server: SDOPDSServer) async throws -> Data {
        let (data, _) = try await fetchDataWithResponse(url: url, credential: credential, server: server)
        return data
    }

    private func buildRequest(url: URL, credential: OPDSCredential?, server: SDOPDSServer) -> URLRequest {
        var request = URLRequest(url: url)
        // Accept both OPDS 1.x Atom XML and OPDS 2.0 / Readium JSON formats.
        // Komga v2 will return application/opds+json when this is in the Accept header.
        request.setValue(
            "application/opds+json, application/opds-publication+json, " +
            "application/webpub+json, application/divina+json, " +
            "application/atom+xml, application/xml, */*",
            forHTTPHeaderField: "Accept"
        )
        request.timeoutInterval = 30

        if server.serverType == .kavita {
            // Kavita: JWT Bearer — token lives in Keychain as credential.bearerToken
            if let token = credential?.bearerToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        } else {
            // Komga / Calibre / calibre-web: HTTP Basic Auth
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

// MARK: - Errors

enum OPDSError: LocalizedError {
    case invalidURL
    case parseFailure
    case noDownloadURL
    case httpError(Int)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:              return "The server URL is invalid."
        case .parseFailure:            return "Could not parse the server's OPDS feed."
        case .noDownloadURL:           return "This entry does not have a download link."
        case .httpError(let code):     return "Server responded with error \(code)."
        case .connectionFailed(let m): return m
        }
    }
}
