import Foundation

// MARK: - Native OPDS Parser (Atom 1.2 & JSON 2.0)

/// High-performance, zero-dependency native OPDS parser.
/// Supports both OPDS 1.2 XML/Atom feeds and OPDS 2.0 JSON manifests.
public final class NativeOPDSParser: NSObject, Sendable {

    /// Parses raw feed data (XML Atom or JSON) into a strongly typed `OPDSFeed`.
    public static func parse(data: Data, baseURL: URL) throws -> OPDSFeed {
        // Quick detection: JSON vs XML
        if let firstByte = data.first, (firstByte == 0x7B /* '{' */ || firstByte == 0x5B /* '[' */) {
            if let jsonFeed = try? parseJSON(data: data, baseURL: baseURL) {
                return jsonFeed
            }
        }

        let parser = AtomXMLParser(data: data, baseURL: baseURL)
        return try parser.parse()
    }

    // MARK: - OPDS 2.0 JSON Parser Fallback

    private static func parseJSON(data: Data, baseURL: URL) throws -> OPDSFeed {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OPDSParseError.invalidFormat
        }

        let metadata = root["metadata"] as? [String: Any] ?? [:]
        let title = metadata["title"] as? String ?? "OPDS Catalog"
        let id = metadata["identifier"] as? String ?? baseURL.absoluteString

        var entries: [OPDSEntry] = []
        if let pubs = root["publications"] as? [[String: Any]] {
            for pub in pubs {
                let meta = pub["metadata"] as? [String: Any] ?? [:]
                let entryTitle = meta["title"] as? String ?? "Untitled"
                let entryID = meta["identifier"] as? String ?? UUID().uuidString
                var authors: [String] = []
                if let authorArr = meta["author"] as? [[String: Any]] {
                    authors = authorArr.compactMap { $0["name"] as? String }
                } else if let singleAuthor = meta["author"] as? String {
                    authors = [singleAuthor]
                }
                let summary = meta["description"] as? String

                var links: [OPDSLink] = []
                if let linkArr = pub["links"] as? [[String: Any]] {
                    for l in linkArr {
                        if let href = l["href"] as? String {
                            let rel = l["rel"] as? String ?? "acquisition"
                            let type = l["type"] as? String
                            links.append(OPDSLink(rel: rel, href: href, type: type))
                        }
                    }
                }
                if let imageArr = pub["images"] as? [[String: Any]] {
                    for img in imageArr {
                        if let href = img["href"] as? String {
                            let type = img["type"] as? String
                            links.append(OPDSLink(rel: "http://opds-spec.org/image", href: href, type: type))
                        }
                    }
                }

                entries.append(OPDSEntry(
                    id: entryID,
                    title: entryTitle,
                    authors: authors,
                    summary: summary,
                    links: links
                ))
            }
        }

        var navLinks: [OPDSLink] = []
        if let navArr = root["navigation"] as? [[String: Any]] {
            for n in navArr {
                if let href = n["href"] as? String {
                    let title = n["title"] as? String ?? "Browse"
                    let type = n["type"] as? String
                    navLinks.append(OPDSLink(rel: "subsection", href: href, type: type, title: title))
                }
            }
        }

        return OPDSFeed(
            title: title,
            id: id,
            entries: entries,
            navigationLinks: navLinks
        )
    }
}

public enum OPDSParseError: LocalizedError, Sendable {
    case invalidFormat
    case parsingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "The OPDS server response is not in a valid XML or JSON catalog format."
        case .parsingFailed(let msg): return "OPDS parsing error: \(msg)"
        }
    }
}

// MARK: - Internal Atom XML Parser

private final class AtomXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let baseURL: URL

    private var feedTitle: String = ""
    private var feedID: String = ""
    private var feedIconURL: URL?
    private var feedUpdated: Date?
    private var entries: [OPDSEntry] = []
    private var feedLinks: [OPDSLink] = []

    // State machine tracking
    private var currentElement: String = ""
    private var currentText: String = ""
    private var inEntry: Bool = false
    private var inAuthor: Bool = false

    // Entry accumulator
    private var entryID: String = ""
    private var entryTitle: String = ""
    private var entryAuthors: [String] = []
    private var entrySummary: String = ""
    private var entryContent: String = ""
    private var entryLinks: [OPDSLink] = []
    private var entryCategories: [String] = []
    private var entryUpdated: Date?

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(data: Data, baseURL: URL) {
        self.data = data
        self.baseURL = baseURL
    }

    func parse() throws -> OPDSFeed {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldReportNamespacePrefixes = false
        xmlParser.shouldResolveExternalEntities = false

        if !xmlParser.parse() {
            let err = xmlParser.parserError?.localizedDescription ?? "Unknown XML error"
            throw OPDSParseError.parsingFailed(err)
        }

        var navLinks: [OPDSLink] = []
        var searchLink: OPDSLink?
        var nextLink: OPDSLink?

        for link in feedLinks {
            let rel = link.rel.lowercased()
            if rel.contains("search") {
                searchLink = link
            } else if rel == "next" {
                nextLink = link
            } else if rel.contains("subsection") || rel.contains("start") || rel.contains("up") || rel.contains("collection") {
                navLinks.append(link)
            }
        }

        return OPDSFeed(
            title: feedTitle.isEmpty ? "Catalog" : feedTitle,
            id: feedID.isEmpty ? baseURL.absoluteString : feedID,
            iconURL: feedIconURL,
            updated: feedUpdated,
            entries: entries,
            navigationLinks: navLinks,
            searchLink: searchLink,
            nextPageLink: nextLink
        )
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""

        if currentElement == "entry" {
            inEntry = true
            entryID = ""
            entryTitle = ""
            entryAuthors = []
            entrySummary = ""
            entryContent = ""
            entryLinks = []
            entryCategories = []
            entryUpdated = nil
        } else if currentElement == "author" {
            inAuthor = true
        } else if currentElement == "link" {
            if let href = attributeDict["href"] {
                let rel = attributeDict["rel"] ?? "related"
                let type = attributeDict["type"]
                let title = attributeDict["title"]
                let link = OPDSLink(rel: rel, href: href, type: type, title: title)
                if inEntry {
                    entryLinks.append(link)
                } else {
                    feedLinks.append(link)
                }
            }
        } else if currentElement == "category" {
            if let term = attributeDict["label"] ?? attributeDict["term"] {
                if inEntry {
                    entryCategories.append(term)
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let element = elementName.lowercased()

        if inEntry {
            switch element {
            case "id":
                entryID = trimmed
            case "title":
                entryTitle = trimmed
            case "name" where inAuthor:
                if !trimmed.isEmpty { entryAuthors.append(trimmed) }
            case "summary":
                entrySummary = trimmed
            case "content":
                entryContent = trimmed
            case "updated":
                entryUpdated = Self.isoDateFormatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
            case "author":
                inAuthor = false
            case "entry":
                inEntry = false
                let entry = OPDSEntry(
                    id: entryID.isEmpty ? UUID().uuidString : entryID,
                    title: entryTitle.isEmpty ? "Untitled Book" : entryTitle,
                    authors: entryAuthors,
                    summary: entrySummary.isEmpty ? (entryContent.isEmpty ? nil : entryContent) : entrySummary,
                    content: entryContent.isEmpty ? nil : entryContent,
                    updated: entryUpdated,
                    links: entryLinks,
                    categories: entryCategories
                )
                entries.append(entry)
            default:
                break
            }
        } else {
            switch element {
            case "title":
                feedTitle = trimmed
            case "id":
                feedID = trimmed
            case "icon":
                feedIconURL = URL(string: trimmed, relativeTo: baseURL)
            case "updated":
                feedUpdated = Self.isoDateFormatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
            default:
                break
            }
        }
    }
}
