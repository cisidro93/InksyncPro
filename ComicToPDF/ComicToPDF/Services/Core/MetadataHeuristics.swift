import Foundation
import ZIPFoundation

/// A utility struct to encapsulate string matching and metadata inference rules
/// for comic book filenames to ensure consistency between Single Edit and Batch workflows.
struct MetadataHeuristics {
    
    /// Cleans the raw filename to yield a searchable Series/Volume name.
    ///
    /// - Parameter name: The original file name (e.g., "Batman_(2023)_#12.cbz")
    /// - Returns: A cleaned query string (e.g., "Batman")
    static func cleanFilename(_ name: String) -> String {
        let detected = SeriesNameDetector.detect(from: name)
        var clean = detected.seriesName
        
        // Remove parenthesis content roughly (like year, if we want a clean series search)
        while let range = clean.range(of: "\\(.*?\\)", options: .regularExpression) {
            clean.removeSubrange(range)
        }
        
        // Remove curly brace content roughly
        while let range = clean.range(of: "\\{.*?\\}", options: .regularExpression) {
             clean.removeSubrange(range)
        }
        
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasSuffix("-") || clean.hasSuffix(":") || clean.hasSuffix(";") || clean.hasSuffix(",") {
            clean.removeLast()
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return clean
    }
    
    /// Attempts to extract an issue number from the raw filename using regex.
    ///
    /// - Parameter name: The original file name (e.g., "Batman_#12.cbz")
    /// - Returns: The extracted issue number as a String, if found.
    static func extractIssueNumber(from name: String) -> String? {
        let detected = SeriesNameDetector.detect(from: name)
        return detected.issueNumberString
    }
    
    /// Extract the OPF full-path from container.xml content using regex parsing
    public static func extractOPFPath(from containerStr: String) -> String? {
        // Primary strategy: regex handles both single and double quotes, whitespace variations
        let pattern = "full-path\\s*=\\s*[\"']([^\"']+)[\"']"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: containerStr, options: [], range: NSRange(containerStr.startIndex..., in: containerStr)) {
            if let range = Range(match.range(at: 1), in: containerStr) {
                return String(containerStr[range])
            }
        }
        
        // Fallback: manual split, but ONLY if separator is actually present
        if containerStr.contains("full-path=\"") {
            let parts = containerStr.components(separatedBy: "full-path=\"")
            if parts.count > 1, let opfPath = parts[1].components(separatedBy: "\"").first, !opfPath.isEmpty {
                return opfPath
            }
        }
        if containerStr.contains("full-path='") {
            let parts = containerStr.components(separatedBy: "full-path='")
            if parts.count > 1, let opfPath = parts[1].components(separatedBy: "'").first, !opfPath.isEmpty {
                return opfPath
            }
        }
        return nil
    }

    /// Read first 8 bytes of file for diagnostic signature inspection
    private static func inspectFileHeader(url: URL) -> String {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), !data.isEmpty else { return "empty" }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = String(data: data, encoding: .ascii)?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") ?? ""
        return "[\(hex)] '\(ascii)'"
    }

    /// Intelligently routes manga vs western comics based on heuristic file names and path structures
    static func detectAsymmetricContentType(url: URL) -> ContentType {
        let ext = url.pathExtension.lowercased()
        let headerStr = inspectFileHeader(url: url)
        
        let pathLower = url.path.lowercased()
        let nameLower = url.lastPathComponent.lowercased()
        let parentLower = url.deletingLastPathComponent().lastPathComponent.lowercased()
        
        let mangaKeywords = ["manga", "tankobon", "volume", "chapter", "inuyasha", "shonen", "shoujo", "seinen", "josei", "[raw]", "[ch.", "ch.", "manhwa", "manhua", "scanlation", "oneshot", "doujin"]
        let comicKeywords = ["comic", "graphic novel", "omnibus", "trade paperback", "tpb", "issue", "annual", "deluxe"]
        
        let matchedManga = mangaKeywords.filter { nameLower.contains($0) || parentLower.contains($0) || pathLower.contains("/\($0)/") || pathLower.contains("/\($0)") }
        let matchedComic = comicKeywords.filter { nameLower.contains($0) || parentLower.contains($0) || pathLower.contains("/\($0)/") || pathLower.contains("/\($0)") }
        
        let isManga = !matchedManga.isEmpty || url.pathComponents.map({ $0.lowercased() }).contains("manga")
        let isComic = !matchedComic.isEmpty ||
                      pathLower.contains("/merged/") ||
                      nameLower.contains("_converted") ||
                      nameLower.contains("go merge") ||
                      url.pathComponents.map({ $0.lowercased() }).contains("comic")
        
        var decidedType: ContentType = .book
        var rationale: String = ""
        
        if ext == "pdf" {
            if isManga {
                decidedType = .manga
                rationale = "PDF matched manga keywords: \(matchedManga)"
            } else if isComic {
                decidedType = .comic
                rationale = "PDF matched comic keywords: \(matchedComic)"
            } else {
                // Text-bearing PDFs and standard documents are books
                let importer = PDFImporter()
                if importer.hasTextContent(url: url) {
                    decidedType = .book
                    rationale = "PDF verified with text layer -> .book"
                } else {
                    decidedType = .book
                    rationale = "PDF has no comic keywords, default text book -> .book"
                }
            }
        } else if ext == "epub" {
            // Check if it's fixed layout/comic
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            
            var isEPUBComic = false
            var epubRationale = "Reflowable text EPUB"
            
            do {
                guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else {
                    decidedType = .book
                    rationale = "Could not read EPUB archive -> default .book"
                    Logger.shared.log("MetadataHeuristics: Evaluated '\(url.lastPathComponent)' -> .\(decidedType.rawValue) | Ext: .\(ext) | Header: \(headerStr) | Rationale: \(rationale)", category: "ContentType", type: .info)
                    return .book
                }
                
                if let containerEntry = archive["META-INF/container.xml"] {
                    var containerData = Data()
                    _ = try archive.extract(containerEntry) { data in containerData.append(data) }
                    
                    if let containerStr = String(data: containerData, encoding: .utf8),
                       let opfPath = MetadataHeuristics.extractOPFPath(from: containerStr),
                       let opfEntry = archive[opfPath] {
                        
                        var opfData = Data()
                        _ = try archive.extract(opfEntry) { data in opfData.append(data) }
                        
                        if let opfStr = String(data: opfData, encoding: .utf8) {
                            let lowerOPF = opfStr.lowercased()
                            if lowerOPF.contains("pre-paginated") || 
                               lowerOPF.contains("comic-book") || 
                               lowerOPF.contains("fixed-layout") || 
                               lowerOPF.contains("image-based") ||
                               lowerOPF.contains("manga") {
                                isEPUBComic = true
                                epubRationale = "Fixed-layout/comic OPF metadata detected"
                            }
                        }
                    }
                }
                
                // Fallback strategy: check for dedicated image-comic EPUBs (e.g. Manga/CBZ converted to EPUB)
                // Requires a high volume of images (>= 25) that match or exceed HTML page count
                if !isEPUBComic {
                    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                    var imageCount = 0
                    var htmlCount = 0
                    for entry in archive {
                        let entryPathLower = entry.path.lowercased()
                        let name = (entryPathLower as NSString).lastPathComponent
                        guard !entryPathLower.contains("__macosx"), !name.hasPrefix("._"), name != ".ds_store", !entryPathLower.hasSuffix("/") else { continue }
                        let entryExt = (name as NSString).pathExtension.lowercased()
                        if imageExtensions.contains(entryExt) {
                            imageCount += 1
                        } else if ["xhtml", "html", "htm"].contains(entryExt) {
                            htmlCount += 1
                        }
                    }
                    if imageCount >= 25 && htmlCount > 0 && Double(imageCount) >= Double(htmlCount) * 0.85 {
                        isEPUBComic = true
                        epubRationale = "High image-to-HTML density (\(imageCount) images vs \(htmlCount) pages)"
                    }
                }
                
                if isEPUBComic {
                    if isManga {
                        decidedType = .manga
                        rationale = "EPUB comic (\(epubRationale)) with manga keywords: \(matchedManga)"
                    } else {
                        decidedType = .comic
                        rationale = "EPUB comic (\(epubRationale))"
                    }
                } else {
                    decidedType = .book
                    rationale = epubRationale
                }
            } catch {
                decidedType = .book
                rationale = "Archive inspection error: \(error.localizedDescription) -> default .book"
            }
        } else {
            if isManga {
                decidedType = .manga
                rationale = "Archive format matched manga keywords: \(matchedManga)"
            } else {
                decidedType = .comic
                rationale = "Standard comic archive (CBZ/CBR/CB7/ZIP) -> .comic"
            }
        }
        
        Logger.shared.log(
            "MetadataHeuristics: Evaluated '\(url.lastPathComponent)' -> .\(decidedType.rawValue) | Ext: .\(ext) | Header: \(headerStr) | MangaKeywords: \(matchedManga) | ComicKeywords: \(matchedComic) | Rationale: \(rationale)",
            category: "ContentType",
            type: .info
        )
        return decidedType
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
