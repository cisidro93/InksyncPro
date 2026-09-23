import Foundation

// MARK: - OPDS Models (Sendable & Swift 6 Compliant)

/// Represents a configured OPDS catalog server (e.g. Kavita, Komga, Calibre-Web, Standard Ebooks).
public struct OPDSServer: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var username: String?
    public var password: String?
    public var iconName: String
    public var isPreset: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        username: String? = nil,
        password: String? = nil,
        iconName: String = "books.vertical.fill",
        isPreset: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.iconName = iconName
        self.isPreset = isPreset
    }

    /// Pre-configured high-quality public domain OPDS catalogs
    public static let standardPresets: [OPDSServer] = [
        OPDSServer(
            name: "Standard Ebooks",
            url: URL(string: "https://standardebooks.org/opds/all")!,
            iconName: "book.pages.fill",
            isPreset: true
        ),
        OPDSServer(
            name: "Feedbooks Public Domain",
            url: URL(string: "https://catalog.feedbooks.com/publicdomain/browse.atom")!,
            iconName: "books.vertical.fill",
            isPreset: true
        )
    ]
}

/// Link relation item within an OPDS feed or entry (e.g. acquisition, thumbnail, navigation).
public struct OPDSLink: Hashable, Sendable, Codable {
    public let rel: String
    public let href: String
    public let type: String?
    public let title: String?

    public init(rel: String, href: String, type: String? = nil, title: String? = nil) {
        self.rel = rel
        self.href = href
        self.type = type
        self.title = title
    }

    /// Resolves relative paths against the source feed base URL.
    public func resolvedURL(relativeTo baseURL: URL) -> URL? {
        if let direct = URL(string: href), direct.scheme != nil {
            return direct
        }
        return URL(string: href, relativeTo: baseURL)?.absoluteURL
    }

    /// True if link represents an image representation (cover or thumbnail).
    public var isCover: Bool {
        rel.contains("image") || rel.contains("cover")
    }

    public var isThumbnail: Bool {
        rel.contains("thumbnail") || (rel.contains("image") && !rel.contains("cover"))
    }

    /// True if link triggers an acquisition (download) of the book.
    public var isAcquisition: Bool {
        rel.contains("acquisition") || rel.contains("open-access") || rel.contains("borrow") || (type?.contains("epub") == true || type?.contains("pdf") == true || type?.contains("comic") == true || type?.contains("zip") == true)
    }

    /// User-friendly label for the acquisition format.
    public var formatBadge: String {
        let t = (type ?? "").lowercased()
        let h = href.lowercased()
        if t.contains("epub") || h.hasSuffix(".epub") { return "EPUB" }
        if t.contains("pdf") || h.hasSuffix(".pdf") { return "PDF" }
        if t.contains("comic") || t.contains("cbz") || h.hasSuffix(".cbz") { return "CBZ" }
        if t.contains("cbr") || h.hasSuffix(".cbr") { return "CBR" }
        return "BOOK"
    }
}

/// Represents an individual book or publication within an OPDS feed.
public struct OPDSEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let authors: [String]
    public let summary: String?
    public let content: String?
    public let updated: Date?
    public let links: [OPDSLink]
    public let categories: [String]

    public init(
        id: String,
        title: String,
        authors: [String] = [],
        summary: String? = nil,
        content: String? = nil,
        updated: Date? = nil,
        links: [OPDSLink] = [],
        categories: [String] = []
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.summary = summary
        self.content = content
        self.updated = updated
        self.links = links
        self.categories = categories
    }

    public var authorString: String {
        authors.isEmpty ? "Unknown Author" : authors.joined(separator: ", ")
    }

    public func coverURL(relativeTo baseURL: URL) -> URL? {
        let coverLink = links.first(where: { $0.isCover }) ?? links.first(where: { $0.isThumbnail })
        return coverLink?.resolvedURL(relativeTo: baseURL)
    }

    public func thumbnailURL(relativeTo baseURL: URL) -> URL? {
        let thumbLink = links.first(where: { $0.isThumbnail }) ?? links.first(where: { $0.isCover })
        return thumbLink?.resolvedURL(relativeTo: baseURL)
    }

    public var acquisitionLinks: [OPDSLink] {
        links.filter { $0.isAcquisition }
    }

    public var primaryAcquisitionLink: OPDSLink? {
        // Prioritize EPUB > CBZ > PDF
        acquisitionLinks.first(where: { $0.formatBadge == "EPUB" })
            ?? acquisitionLinks.first(where: { $0.formatBadge == "CBZ" })
            ?? acquisitionLinks.first(where: { $0.formatBadge == "PDF" })
            ?? acquisitionLinks.first
    }
}

/// Represents an OPDS catalog feed page (can contain navigation links or book entries).
public struct OPDSFeed: Sendable {
    public let title: String
    public let id: String
    public let iconURL: URL?
    public let updated: Date?
    public let entries: [OPDSEntry]
    public let navigationLinks: [OPDSLink]
    public let searchLink: OPDSLink?
    public let nextPageLink: OPDSLink?

    public init(
        title: String,
        id: String = UUID().uuidString,
        iconURL: URL? = nil,
        updated: Date? = nil,
        entries: [OPDSEntry] = [],
        navigationLinks: [OPDSLink] = [],
        searchLink: OPDSLink? = nil,
        nextPageLink: OPDSLink? = nil
    ) {
        self.title = title
        self.id = id
        self.iconURL = iconURL
        self.updated = updated
        self.entries = entries
        self.navigationLinks = navigationLinks
        self.searchLink = searchLink
        self.nextPageLink = nextPageLink
    }
}
