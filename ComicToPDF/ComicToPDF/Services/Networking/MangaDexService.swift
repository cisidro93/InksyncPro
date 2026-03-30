import Foundation

enum MangaDexError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case noResults
}

struct MangaDexResult: Codable {
    let data: [MangaDexManga]
}

struct MangaDexManga: Codable, Identifiable {
    let id: String
    let attributes: MangaDexAttributes
}

struct MangaDexAttributes: Codable {
    let title: [String: String]
    let description: [String: String]?
    let year: Int?
    let status: String?
}

struct MangaDexChapterResult: Codable {
    let data: [MangaDexChapter]
}

struct MangaDexChapter: Codable, Identifiable {
    let id: String
    let attributes: MangaDexChapterAttributes
}

struct MangaDexChapterAttributes: Codable {
    let chapter: String?
    let title: String?
    let publishAt: String?
}

class MangaDexService {
    static let shared = MangaDexService()
    
    // MangaDex allows 5 requests per second, so rate limiting is extremely relaxed compared to ComicVine.
    // However, a minimal buffer ensures no accidental bursts cause 429s.
    private var lastRequestTime = Date.distantPast
    
    private init() {}
    
    private func waitForRateLimit() async {
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastRequestTime)
        if timeSinceLast < 0.25 {
            let waitTime = 0.25 - timeSinceLast
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
    
    func searchManga(query: String) async throws -> [MangaDexManga] {
        await waitForRateLimit()
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw MangaDexError.invalidURL
        }
        
        let urlString = "https://api.mangadex.org/manga?title=\(encodedQuery)&limit=10&contentRating[]=safe&contentRating[]=suggestive"
        guard let url = URL(string: urlString) else { throw MangaDexError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw MangaDexError.networkError(NSError(domain: "", code: httpResponse.statusCode))
        }
        
        do {
            let result = try JSONDecoder().decode(MangaDexResult.self, from: data)
            return result.data
        } catch {
            throw MangaDexError.decodingError(error)
        }
    }
    
    func getChapter(mangaID: String, chapterNumber: String) async throws -> MangaDexChapter? {
        await waitForRateLimit()
        
        // Fetch paginated chapters for this Manga ID
        let urlString = "https://api.mangadex.org/chapter?manga=\(mangaID)&chapter=\(chapterNumber)&translatedLanguage[]=en&limit=1"
        guard let url = URL(string: urlString) else { throw MangaDexError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw MangaDexError.networkError(NSError(domain: "", code: httpResponse.statusCode))
        }
        
        let result = try JSONDecoder().decode(MangaDexChapterResult.self, from: data)
        return result.data.first
    }
}
