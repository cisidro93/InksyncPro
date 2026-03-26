import Foundation

// MARK: - Models
struct OPDSFeed {
    let title: String
    let entries: [OPDSEntry]
}

struct OPDSEntry: Identifiable {
    let id: String
    let title: String
    let author: String
    let coverURL: URL?
    let downloadURL: URL?
    let streamURL: URL? // OPDS-PSE (Page Streaming Extension) base URL
    let pageCount: Int // Often exposed in OPDS via <dcterms:extent>
}

// MARK: - XML Parser
class OPDSParser: NSObject, XMLParserDelegate {
    private var feedTitle: String = ""
    private var entries: [OPDSEntry] = []
    
    private var currentElement = ""
    private var currentString = ""
    
    // Entry State
    private var isInsideEntry = false
    private var entryId = ""
    private var entryTitle = ""
    private var entryAuthor = ""
    private var entryCover: URL?
    private var entryDownload: URL?
    private var entryStream: URL?
    private var entryPageCount: Int = 0
    
    func parse(data: Data) -> OPDSFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return OPDSFeed(title: feedTitle.trimmingCharacters(in: .whitespacesAndNewlines), entries: entries)
        }
        return nil
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentString = ""
        
        if elementName == "entry" {
            isInsideEntry = true
            entryId = ""
            entryTitle = ""
            entryAuthor = ""
            entryCover = nil
            entryDownload = nil
            entryStream = nil
            entryPageCount = 0
        }
        
        if elementName == "link" {
            if let rel = attributeDict["rel"], let href = attributeDict["href"] {
                let url = URL(string: href)
                
                if rel.contains("http://opds-spec.org/image") || rel == "thumbnail" {
                    entryCover = url
                } else if rel.contains("http://opds-spec.org/acquisition") {
                    entryDownload = url
                } else if rel.contains("http://vaemendis.net/opds-pse/stream") { // Komga/Kavita PSE Streaming
                    entryStream = url
                }
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentString += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !isInsideEntry {
            if elementName == "title" && feedTitle.isEmpty {
                feedTitle = text
            }
        } else {
            if elementName == "id" {
                entryId = text
            } else if elementName == "title" {
                entryTitle = text
            } else if elementName == "name" { // Simple author check inside <author><name>
                entryAuthor = text
            } else if elementName == "dcterms:extent" || elementName == "schema:numberOfPages" {
                // Parse page count if present
                if let count = Int(text.replacingOccurrences(of: " pages", with: "")) {
                    entryPageCount = count
                }
            } else if elementName == "entry" {
                let entry = OPDSEntry(
                    id: entryId,
                    title: entryTitle,
                    author: entryAuthor,
                    coverURL: entryCover,
                    downloadURL: entryDownload,
                    streamURL: entryStream,
                    pageCount: entryPageCount > 0 ? entryPageCount : 50 // Safe fallback
                )
                entries.append(entry)
                isInsideEntry = false
            }
        }
    }
}

// MARK: - Client
actor OPDSClient {
    static let shared = OPDSClient()
    
    func fetchFeed(url: URL) async throws -> OPDSFeed {
        var request = URLRequest(url: url)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        
        // Setup basic auth if URL has credentials
        if let user = url.user, let password = url.password {
            let loginString = String(format: "%@:%@", user, password)
            if let loginData = loginString.data(using: .utf8) {
                let base64LoginString = loginData.base64EncodedString()
                request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        let parser = OPDSParser()
        guard let feed = parser.parse(data: data) else {
            throw URLError(.cannotParseResponse)
        }
        
        return feed
    }
}
