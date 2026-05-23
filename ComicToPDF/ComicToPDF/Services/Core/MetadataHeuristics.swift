import Foundation

/// A utility struct to encapsulate string matching and metadata inference rules
/// for comic book filenames to ensure consistency between Single Edit and Batch workflows.
struct MetadataHeuristics {
    
    /// Cleans the raw filename to yield a searchable Series/Volume name.
    ///
    /// - Parameter name: The original file name (e.g., "Batman_(2023)_#12.cbz")
    /// - Returns: A cleaned query string (e.g., "Batman")
    static func cleanFilename(_ name: String) -> String {
        var clean = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        
        // Remove underscores and replacing them with spaces
        clean = clean.replacingOccurrences(of: "_", with: " ")
        
        // Remove parenthesis content roughly (e.g. publication years "(2023)")
        if let range = clean.range(of: "\\(.*?\\)", options: .regularExpression) {
             clean.removeSubrange(range)
        }
        
        // Return stripped query
        return clean.trimmingCharacters(in: .whitespaces)
    }
    
    /// Attempts to extract an issue number from the raw filename using regex.
    ///
    /// - Parameter name: The original file name (e.g., "Batman_#12.cbz")
    /// - Returns: The extracted issue number as a String, if found.
    static func extractIssueNumber(from name: String) -> String? {
        // Look for #123 or 123 at the end of parts
        let pattern = "#?(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
            if let range = Range(match.range(at: 1), in: name) {
                return String(name[range])
            }
        }
        return nil
    }
    
    /// Intelligently routes manga vs western comics based on heuristic file names
    static func detectAsymmetricContentType(url: URL) -> ContentType {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || ext == "epub" { return .book }
        
        // Scanlation signatures
        let nameLower = url.lastPathComponent.lowercased()
        let parentLower = url.deletingLastPathComponent().lastPathComponent.lowercased()
        let mangaKeywords = ["[raw]", "[ch.", "ch.", "manhwa", "manhua", "manga", "scanlation", "oneshot", "doujin"]
        
        if mangaKeywords.contains(where: { nameLower.contains($0) || parentLower.contains($0) }) {
            return .manga
        }
        
        return .comic
    }
}

// MARK: - BookVine (Google Books API) Services
// Embedded here to avoid manual 'project.pbxproj' reference updates dynamically.

/// Defines the structure returned by the Google Books API
struct GoogleBooksResponse: Codable {
    let items: [GoogleBookItem]?
}

struct GoogleBookItem: Codable, Identifiable {
    let id: String
    let volumeInfo: GoogleBookVolumeInfo
}

struct GoogleBookVolumeInfo: Codable {
    let title: String
    let subtitle: String?
    let authors: [String]?
    let publisher: String?
    let publishedDate: String?
    let description: String?
    let pageCount: Int?
    let industryIdentifiers: [GoogleBookIdentifier]?
    let imageLinks: GoogleBookImageLinks?
}

struct GoogleBookIdentifier: Codable {
    let type: String
    let identifier: String
}

struct GoogleBookImageLinks: Codable {
    let thumbnail: String?
    let smallThumbnail: String?
    let small: String?
    let medium: String?
    let large: String?
    let extraLarge: String?
    
    // Helper to get the highest resolution available
    var bestQualityURL: String? {
        let urlStr = extraLarge ?? large ?? medium ?? small ?? thumbnail ?? smallThumbnail
        return urlStr?.replacingOccurrences(of: "http://", with: "https://")
    }
}

/// Service responsible for fetching metadata for novels, textbooks, and EPUBs from the Google Books API.
final class BookMetadataService: Sendable {
    static let shared = BookMetadataService()
    
    private init() {}
    
    func searchBooks(query: String) async throws -> [GoogleBookItem] {
        let cleanQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://www.googleapis.com/books/v1/volumes?q=\(cleanQuery)&maxResults=40"
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoded = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
        return decoded.items ?? []
    }
    
    func searchByISBN(_ isbn: String) async throws -> GoogleBookItem? {
        let cleanISBN = isbn.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        let results = try await searchBooks(query: "isbn:\(cleanISBN)")
        return results.first
    }
}
