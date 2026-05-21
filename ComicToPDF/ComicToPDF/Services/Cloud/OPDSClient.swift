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
            insideEntry     = true
            entryID         = ""
            entryTitle      = ""
            entryAuthor     = ""
            entryCoverURL   = nil
            entryDownloadURL = nil
            entryStreamURL  = nil
            entryPageCount  = nil
            entryIsNavigation = false
            entryNavFeedURL = nil

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

        } else if rel.contains("vaemendis.net/opds-pse/stream") ||
                  rel.contains("opds-pse") {
            // OPDS-PSE page streaming (Kavita / Komga)
            entryStreamURL = url

        } else if rel == "subsection" || rel == "http://opds-spec.org/subsection" {
            // Navigation feed — drill-down catalog link
            entryIsNavigation = true
            entryNavFeedURL = url
        }
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
                id:          entryID.isEmpty ? UUID().uuidString : entryID,
                title:       entryTitle,
                author:      entryAuthor,
                coverURL:    entryCoverURL,
                downloadURL: entryDownloadURL,
                streamURL:   entryStreamURL,
                pageCount:   entryPageCount,
                kind:        entryIsNavigation ? .navigation : .acquisition
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
actor OPDSClient {

    static let shared = OPDSClient()

    // MARK: - Fetch Feed

    /// Fetches and parses an OPDS feed at the given `path` on `server`.
    /// `path` is relative to `server.baseURL` (pass "" or "/" for the root).
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

        let data = try await fetchData(url: targetURL, credential: credential, server: server)
        guard let feed = OPDSFeedParser().parse(data: data) else {
            throw OPDSError.parseFailure
        }
        Logger.shared.log("OPDSClient: fetched feed '\(feed.title)' (\(feed.entries.count) entries, \(feed.navLinks.count) nav)", category: "OPDS")
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

        let data = try await fetchData(url: url, credential: credential, server: server)
        guard let feed = OPDSFeedParser().parse(data: data) else { throw OPDSError.parseFailure }
        return feed
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private func fetchData(url: URL, credential: OPDSCredential?, server: SDOPDSServer) async throws -> Data {
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
        return data
    }

    private func buildRequest(url: URL, credential: OPDSCredential?, server: SDOPDSServer) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/atom+xml, application/xml, */*", forHTTPHeaderField: "Accept")
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
