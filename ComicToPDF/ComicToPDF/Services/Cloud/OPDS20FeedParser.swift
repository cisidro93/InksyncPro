import Foundation

// MARK: - OPDS 2.0 / Readium WebPub Manifest Parser

/// Parses OPDS 2.0 JSON feeds (Content-Type: application/opds+json) and
/// Readium WebPub Manifest / Divina publications (application/opds-publication+json).
///
/// The output is the same OPDSFeed / OPDSEntry model used by the existing
/// Atom XML pipeline — the UI layer (OPDSBrowserView, OPDSBookGrid, OPDSPSEReader)
/// requires zero changes.
///
/// Supported servers (May 2026):
///   • Komga  — /opds/v2/catalog  (full OPDS 2.0 + Divina readingOrder streaming)
///   • Kavita — still Atom XML + PSE; OPDS 2.0 not on their roadmap
///
/// Detection: OPDSClient inspects the HTTP response Content-Type header.
///   application/opds+json            → OPDS20FeedParser
///   application/opds-publication+json → OPDS20FeedParser (single pub manifest)
///   anything else                     → existing OPDSFeedParser (Atom XML)
final class OPDS20FeedParser {

    // MARK: - Public entry point

    /// Parse an OPDS 2.0 JSON feed or a single Readium WebPub/Divina manifest.
    /// - Parameters:
    ///   - data: Raw JSON bytes from the server.
    ///   - baseURL: The URL the data was fetched from, used to resolve relative hrefs.
    /// - Returns: An `OPDSFeed` in the same shape as the Atom XML parser, or nil on parse failure.
    func parse(data: Data, baseURL: URL) -> OPDSFeed? {
        let jsonRaw = try? JSONSerialization.jsonObject(with: data)
        guard let json = jsonRaw as? [String: Any] else {
            return nil
        }

        // Detect if this is a single publication manifest vs a catalog feed.
        // A catalog feed has "navigation" or "publications" or "groups" at the top level.
        // A single publication (Divina/WebPub) has "readingOrder" or "spine".
        if json["readingOrder"] != nil || json["spine"] != nil {
            return parseSinglePublication(json: json, baseURL: baseURL)
        }
        return parseCatalogFeed(json: json, baseURL: baseURL)
    }

    // MARK: - Catalog Feed Parser

    private func parseCatalogFeed(json: [String: Any], baseURL: URL) -> OPDSFeed {
        // Feed title from metadata.title
        let feedTitle: String
        if let meta = json["metadata"] as? [String: Any],
           let title = meta["title"] as? String {
            feedTitle = title
        } else {
            feedTitle = ""
        }

        // Feed-level links: self, next, search
        var nextPageURL: URL?
        var searchURL: URL?
        if let links = json["links"] as? [[String: Any]] {
            for link in links {
                guard let rel = link["rel"] as? String,
                      let href = link["href"] as? String,
                      let url = resolvedURL(href, base: baseURL) else { continue }
                if rel == "next" { nextPageURL = url }
                else if rel == "search" || (link["type"] as? String ?? "").contains("opensearch") {
                    searchURL = url
                }
            }
        }

        var navLinks: [OPDSNavLink] = []
        var entries: [OPDSEntry] = []

        // --- Navigation collection ---
        if let navArray = json["navigation"] as? [[String: Any]] {
            for item in navArray {
                if let nav = parseNavLink(item, base: baseURL) {
                    navLinks.append(nav)
                }
            }
        }

        // --- Publications collection ---
        if let pubs = json["publications"] as? [[String: Any]] {
            for pub in pubs {
                if let entry = parsePublication(pub, base: baseURL) {
                    entries.append(entry)
                }
            }
        }

        // --- Groups (each group may contain navigation or publications) ---
        if let groups = json["groups"] as? [[String: Any]] {
            for group in groups {
                if let navArray = group["navigation"] as? [[String: Any]] {
                    for item in navArray {
                        if let nav = parseNavLink(item, base: baseURL) {
                            navLinks.append(nav)
                        }
                    }
                }
                if let pubs = group["publications"] as? [[String: Any]] {
                    for pub in pubs {
                        if let entry = parsePublication(pub, base: baseURL) {
                            entries.append(entry)
                        }
                    }
                }
            }
        }

        return OPDSFeed(
            title: feedTitle,
            entries: entries,
            navLinks: navLinks,
            searchURL: searchURL,
            nextPageURL: nextPageURL
        )
    }

    // MARK: - Single Publication / Divina Manifest

    /// Converts a standalone Readium WebPub / Divina manifest into an OPDSFeed
    /// containing a single OPDSEntry whose `streamURL` is the first readingOrder item.
    ///
    /// OPDSPSEReader already handles any image-href-based streaming as long as
    /// the href is pre-resolved. For Divina we synthesise a PSE-compatible URL
    /// using the readingOrder index: `readingOrder[{pageNumber}].href`.
    private func parseSinglePublication(json: [String: Any], baseURL: URL) -> OPDSFeed {
        let entry = parsePublication(json, base: baseURL)
        return OPDSFeed(
            title: (json["metadata"] as? [String: Any])?["title"] as? String ?? "",
            entries: entry.map { [$0] } ?? [],
            navLinks: [],
            searchURL: nil,
            nextPageURL: nil
        )
    }

    // MARK: - Publication → OPDSEntry

    private func parsePublication(_ pub: [String: Any], base: URL) -> OPDSEntry? {
        let meta = pub["metadata"] as? [String: Any] ?? [:]
        let title = meta["title"] as? String ?? ""
        guard !title.isEmpty else { return nil }

        let author: String
        if let authorArr = meta["author"] as? [[String: Any]] {
            author = authorArr.compactMap { $0["name"] as? String }.joined(separator: ", ")
        } else if let authorStr = meta["author"] as? String {
            author = authorStr
        } else {
            author = ""
        }

        let pageCount = meta["numberOfPages"] as? Int

        var coverURL: URL?
        var downloadURL: URL?
        var streamURL: URL?
        var komgaBookId: String?

        // Publication-level links (cover, download, self)
        let links = pub["links"] as? [[String: Any]] ?? []
        for link in links {
            guard let href = link["href"] as? String else { continue }
            let rel = link["rel"] as? String ?? ""
            let type_ = link["type"] as? String ?? ""
            let url = resolvedURL(href, base: base)

            if rel.contains("opds-spec.org/image") || rel == "thumbnail" || type_.hasPrefix("image/") {
                if coverURL == nil { coverURL = url }
            } else if rel.contains("opds-spec.org/acquisition") || type_.contains("cbz") ||
                      type_.contains("cbr") || type_.contains("pdf") || type_.contains("epub") {
                if downloadURL == nil { downloadURL = url }
                if let h = url?.absoluteString { komgaBookId = extractKomgaBookId(from: h) }
            } else if rel == "self", let url {
                // For Komga: extract book ID from the self link if not yet found
                if komgaBookId == nil {
                    komgaBookId = extractKomgaBookId(from: url.absoluteString)
                }
            }
        }

        // Images collection (OPDS 2.0 separates covers into an "images" sub-collection)
        if let images = pub["images"] as? [[String: Any]] {
            for img in images {
                guard let href = img["href"] as? String,
                      let url = resolvedURL(href, base: base) else { continue }
                let rel = img["rel"] as? String ?? ""
                let type_ = img["type"] as? String ?? ""
                if rel == "thumbnail" || type_.contains("jpeg") || type_.contains("png") {
                    if coverURL == nil { coverURL = url }
                }
            }
        }

        // Divina readingOrder → synthesize a Divina stream URL.
        // We store the manifest's own URL as `streamURL` with a special scheme
        // so OPDSDivinaReader can fetch individual pages by index.
        // The base URL (manifest URL) is used as the stream root.
        var divinaPageURLs: [URL] = []
        if let readingOrder = pub["readingOrder"] as? [[String: Any]] {
            divinaPageURLs = readingOrder.compactMap { item in
                guard let href = item["href"] as? String else { return nil }
                return resolvedURL(href, base: base)
            }
            // If we have a readingOrder, the stream URL is a special divinamanifest:// URL
            // that OPDSClient will store as per-entry metadata.
            // The actual per-page fetching is done by OPDSDivinaReader.
            // We store the first page URL as a sentinel so the entry appears streamable.
            streamURL = divinaPageURLs.first
        }

        // Entry ID: use komgaBookId path or title-based UUID
        let entryID = komgaBookId.map { "komga-book-\($0)" } ?? UUID().uuidString

        return OPDSEntry(
            id: entryID,
            title: title,
            author: author,
            coverURL: coverURL,
            downloadURL: downloadURL,
            streamURL: streamURL,
            pageCount: pageCount ?? divinaPageURLs.count.nonZero,
            kind: .acquisition,
            kavitaChapterId: nil,
            kavitaVolumeId: nil,
            kavitaSeriesId: nil,
            kavitaLibraryId: nil,
            komgaBookId: komgaBookId,
            pseLastRead: nil,
            // Phase 3: store the resolved page URL list for Divina streaming
            divinaPageURLs: divinaPageURLs.isEmpty ? nil : divinaPageURLs
        )
    }

    // MARK: - NavLink

    private func parseNavLink(_ item: [String: Any], base: URL) -> OPDSNavLink? {
        guard let href = item["href"] as? String,
              let title = item["title"] as? String,
              let url = resolvedURL(href, base: base) else { return nil }
        let id = href   // stable ID from href
        return OPDSNavLink(id: id, title: title, feedURL: url)
    }

    // MARK: - Helpers

    private func resolvedURL(_ href: String, base: URL) -> URL? {
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return URL(string: href)
        }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    private func extractKomgaBookId(from href: String) -> String? {
        // /opds/v2/books/{bookId}/...   or   /api/v1/books/{bookId}/...
        guard let range = href.range(of: #"/books/([A-Z0-9a-z\-]+)"#, options: .regularExpression) else { return nil }
        let segment = String(href[range])
        let bookId = segment.replacingOccurrences(of: "/books/", with: "")
            .components(separatedBy: "/").first ?? ""
        return bookId.isEmpty ? nil : bookId
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
