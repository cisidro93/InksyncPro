import Foundation

/// A unified model representing a cover variant found online.
struct FetchedCover: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let sourceName: String // e.g., "Apple Books", "Google Books", "AI Hunter"
    var isAIHunted: Bool = false
    
    // Hashable conformance based on URL to easily filter duplicates
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
    
    static func == (lhs: FetchedCover, rhs: FetchedCover) -> Bool {
        return lhs.url == rhs.url
    }
}

class CoverFetchService {
    static let shared = CoverFetchService()
    
    private init() {}
    
    /// Fetches covers concurrently from all configured sources and returns a unified array.
    /// - Parameters:
    ///   - metadata: The existing PDFMetadata, used to construct queries.
    ///   - openAIKey: Optional user-provided API key for advanced AI hunting.
    ///   - limit: Maximum number of results to fetch (approximate due to concurrent aggregation).
    func fetchCovers(for metadata: PDFMetadata, openAIKey: String? = nil, limit: Int = 10) async -> [FetchedCover] {
        var allCovers: [FetchedCover] = []
        
        // Base Query construction
        var queryParts = [metadata.title]
        if let series = metadata.series, !series.isEmpty, !metadata.title.localizedCaseInsensitiveContains(series) {
            queryParts.append(series)
        }
        if let issue = metadata.issueNumber, !issue.isEmpty {
            queryParts.append("#\(issue)")
        }
        let baseQuery = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let fallbackQuery = metadata.title.trimmingCharacters(in: .whitespaces) // Broadest query if specific fails
        guard !fallbackQuery.isEmpty else { return [] }
        
        let fetchQuery = baseQuery.isEmpty ? fallbackQuery : baseQuery
        
        // Concurrent fetching
        let fetchedSets = await withTaskGroup(of: [FetchedCover].self) { group in
            // 1. Apple Books (iTunes Search API)
            group.addTask { await self.fetchiTunesCovers(query: fetchQuery, limit: limit) }
            // 2. Google Books API
            group.addTask { await self.fetchGoogleBooksCovers(query: fetchQuery, limit: limit) }
            // 3. OpenLibrary API
            group.addTask { await self.fetchOpenLibraryCovers(query: fetchQuery, limit: limit) }
            
            // 4. Existing ComicVine Fallback (If Metadata contains ID)
            if let volID = metadata.seriesID, let issueNum = metadata.issueNumber {
                group.addTask { await self.fetchComicVineIssueCover(volumeID: volID, issueNumber: issueNum) }
            }
            
            // 5. Active AI Agent Hunter
            if let aiKey = openAIKey, !aiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Determine if it's a comic or a book to tune the prompt
                let isComic = (metadata.series != nil || metadata.issueNumber != nil || metadata.writer != nil || metadata.comicVineID != nil)
                group.addTask { await self.fetchAICovers(query: fetchQuery, isComic: isComic, apiKey: aiKey, limit: limit) }
            }
            
            var results: [[FetchedCover]] = []
            for await resultSet in group {
                results.append(resultSet)
            }
            return results
        }
        
        // Deduplicate safely
        var uniqueURLs = Set<URL>()
        
        // Interleave results to get a mix of sources up top
        var hasMore = true
        var index = 0
        while hasMore && allCovers.count < limit {
            hasMore = false
            for set in fetchedSets {
                if index < set.count {
                    hasMore = true
                    let cover = set[index]
                    if !uniqueURLs.contains(cover.url) {
                        uniqueURLs.insert(cover.url)
                        allCovers.append(cover)
                    }
                }
            }
            index += 1
        }
        
        return allCovers
    }
    
    // MARK: - Core Fetchers
    
    private func fetchiTunesCovers(query: String, limit: Int) async -> [FetchedCover] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=ebook&limit=\(limit)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                return results.compactMap { result in
                    if let artworkUrlRaw = result["artworkUrl100"] as? String {
                        // Secret Apple API hack: Replacing 100x100bb with a much larger bounds returns high res original
                        let highResURLString = artworkUrlRaw.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
                        if let imgURL = URL(string: highResURLString) {
                            return FetchedCover(url: imgURL, sourceName: "Apple Books")
                        }
                    }
                    return nil
                }
            }
        } catch {}
        return []
    }
    
    private func fetchGoogleBooksCovers(query: String, limit: Int) async -> [FetchedCover] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=\(encoded)&maxResults=\(limit)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                return items.compactMap { item in
                    if let volumeInfo = item["volumeInfo"] as? [String: Any],
                       let imageLinks = volumeInfo["imageLinks"] as? [String: Any],
                       var thumbnail = imageLinks["thumbnail"] as? String {
                        
                        // Google Books returns Edge/Zoomed compressed images. Clean it up.
                        thumbnail = thumbnail.replacingOccurrences(of: "http://", with: "https://").replacingOccurrences(of: "&zoom=1", with: "&zoom=0").replacingOccurrences(of: "&edge=curl", with: "")
                        
                        if let imgURL = URL(string: thumbnail) {
                            return FetchedCover(url: imgURL, sourceName: "Google Books")
                        }
                    }
                    return nil
                }
            }
        } catch {}
        return []
    }
    
    private func fetchOpenLibraryCovers(query: String, limit: Int) async -> [FetchedCover] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://openlibrary.org/search.json?q=\(encoded)&limit=\(limit)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let docs = json["docs"] as? [[String: Any]] {
                return docs.compactMap { doc in
                    if let coverI = doc["cover_i"] as? Int {
                        // OpenLibrary allows fetching large (-L) covers by DB ID
                        if let imgURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverI)-L.jpg") {
                            return FetchedCover(url: imgURL, sourceName: "Open Library")
                        }
                    }
                    return nil
                }
            }
        } catch {}
        return []
    }
    
    private func fetchComicVineIssueCover(volumeID: Int, issueNumber: String) async -> [FetchedCover] {
        // We do a brief safe check. This avoids hitting rate limits carelessly.
        // We assume the user has configured CV or we're using a standard fetch.
        // If we hit a rate limit, we just return empty array gracefully.
        do {
            // Using a generic app key placeholder if no user key is passed to avoid burning it.
            // Ideally, we'd inject the User's CV key if they had one in Settings. For now, rely on standard CV service handling.
            // But since ComicVineService requires an apiKey parameter:
            let defaultKey = UserDefaults.standard.string(forKey: "comicVineAPIKey") ?? ""
            guard !defaultKey.isEmpty else { return [] }
            
            if let issueDetails = try await ComicVineService.shared.getIssue(volumeID: volumeID, issueNumber: issueNumber, apiKey: defaultKey) {
                if let originalStr = issueDetails.image?.original_url ?? issueDetails.image?.medium_url, let url = URL(string: originalStr) {
                    return [FetchedCover(url: url, sourceName: "ComicVine DB")]
                }
            }
        } catch {
            // Ignore failures silently (rate limit, missing key) for the aggressive fetcher
        }
        return []
    }
    
    // MARK: - Advanced AI Hunter (OpenAI Direct Payload)
    
    private func fetchAICovers(query: String, isComic: Bool, apiKey: String, limit: Int) async -> [FetchedCover] {
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let targetType = isComic ? "comic book variant covers, virgin covers, or artist specific limited editions" : "high-resolution alternative book covers, regional releases, or anniversary editions"
        
        let prompt = """
        You are an autonomous metadata scraping agent. 
        Your task is to find direct image URLs for \(targetType) matching the title: "\(query)".
        Return exactly \(limit) valid, high-resolution direct image URLs (.jpg or .png) from public fan databases, publisher CDN drops, wikis (e.g., Fandom, Marvel Wiki, DC Database), or open portfolios.
        
        You MUST return ONLY a raw JSON dictionary with a single key "urls" mapping to an array of strings. Do not use markdown blocks. Do not explain anything. 
        Example:
        {"urls": ["https://example.com/cover1.jpg"]}
        """
        
        let payload: [String: Any] = [
            "model": "gpt-4o-mini", // Fast, cheap, capable of web URL recall
            "messages": [
                ["role": "system", "content": "You output strict JSON with no markdown formatting."],
                ["role": "user", "content": prompt]
            ],
            // Low temperature for more deterministic/factual URL extraction
            "temperature": 0.2
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            
            struct OpenAIResponse: Codable {
                struct Choice: Codable {
                    struct Message: Codable {
                        let content: String
                    }
                    let message: Message
                }
                let choices: [Choice]
            }
            
            let decoder = JSONDecoder()
            let aiResult = try decoder.decode(OpenAIResponse.self, from: data)
            guard let content = aiResult.choices.first?.message.content else { return [] }
            
            struct AIURLPayload: Codable {
                let urls: [String]
            }
            
            // Clean AI Output if it disobeyed and added markdown
            let cleanJSON = content.replacingOccurrences(of: "```json", with: "")
                                   .replacingOccurrences(of: "```", with: "")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let rawData = cleanJSON.data(using: .utf8) {
                let parsedURLs = try decoder.decode(AIURLPayload.self, from: rawData)
                return parsedURLs.urls.compactMap {
                    if let url = URL(string: $0) {
                        return FetchedCover(url: url, sourceName: "AI Cover Hunter", isAIHunted: true)
                    }
                    return nil
                }
            }
        } catch {
            Logger.shared.log("AI Hunter Error: \(error.localizedDescription)", category: "Network", type: .error)
        }
        
        return []
    }
}
