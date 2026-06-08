import Foundation
import UIKit

enum AniListError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case noResults
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid AniList API endpoint URL."
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingError(let err): return "Failed to parse AniList response: \(err.localizedDescription)"
        case .noResults: return "No manga matching this query was found on AniList."
        }
    }
}

// MARK: - AniList API Models

struct AniListResponse: Codable {
    let data: AniListPageData
}

struct AniListPageData: Codable {
    let Page: AniListMediaPage
}

struct AniListMediaPage: Codable {
    let media: [AniListManga]
}

struct AniListManga: Codable, Identifiable {
    let id: Int
    let title: AniListTitle
    let description: String?
    let coverImage: AniListCoverImage?
    let startDate: AniListDate?
    let staff: AniListStaffConnection?
    let format: String?
    let genres: [String]?
    
    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
        
        var preferredTitle: String {
            if let eng = english, !eng.isEmpty { return eng }
            if let rom = romaji, !rom.isEmpty { return rom }
            return native ?? "Unknown Title"
        }
    }
    
    struct AniListCoverImage: Codable {
        let extraLarge: String?
        let large: String?
        let medium: String?
        
        var bestImageURL: String? {
            return extraLarge ?? large ?? medium
        }
    }
    
    struct AniListDate: Codable {
        let year: Int?
        let month: Int?
        let day: Int?
        
        var toDate: Date? {
            guard let y = year else { return nil }
            var comps = DateComponents()
            comps.year = y
            comps.month = month ?? 1
            comps.day = day ?? 1
            return Calendar.current.date(from: comps)
        }
    }
    
    struct AniListStaffConnection: Codable {
        let edges: [AniListStaffEdge]?
    }
    
    struct AniListStaffEdge: Codable {
        let role: String?
        let node: AniListStaffNode?
    }
    
    struct AniListStaffNode: Codable {
        let name: AniListStaffName?
    }
    
    struct AniListStaffName: Codable {
        let full: String?
    }
    
    var creatorNames: String? {
        guard let edges = staff?.edges else { return nil }
        // Filter roles like "Story & Art", "Story", "Art", "Original Creator", etc.
        let creators = edges.filter { edge in
            guard let role = edge.role?.lowercased() else { return false }
            return role.contains("story") || role.contains("art") || role.contains("creator") || role.contains("illustration")
        }.compactMap { $0.node?.name?.full }
        
        let uniqueCreators = Array(Set(creators)).sorted()
        return uniqueCreators.isEmpty ? nil : uniqueCreators.joined(separator: ", ")
    }
}

// MARK: - AniList Service Actor

actor AniListService {
    static let shared = AniListService()
    
    // In-memory query cache to prevent redundant api calls
    private var searchCache: [String: [AniListManga]] = [:]
    
    // Rate Limiting: 1 request per second spacing
    private var lastRequestTime: Date = Date.distantPast
    private let minRequestInterval: TimeInterval = 1.0
    
    private init() {}
    
    private func throttle() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minRequestInterval {
            let delay = minRequestInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
    
    func searchManga(query: String) async throws -> [AniListManga] {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanedQuery.isEmpty else { return [] }
        
        // 1. Check Cache first to eliminate duplicate network calls
        if let cached = searchCache[cleanedQuery] {
            Logger.shared.log("AniList Cache Hit for query: '\(cleanedQuery)'", category: "Metadata", type: .info)
            return cached
        }
        
        // 2. Throttle calls to respect rate guidelines
        await throttle()
        
        guard let url = URL(string: "https://graphql.anilist.co") else {
            throw AniListError.invalidURL
        }
        
        let graphqlQuery = """
        query ($search: String) {
          Page(page: 1, perPage: 15) {
            media(search: $search, type: MANGA) {
              id
              title {
                romaji
                english
                native
              }
              description
              coverImage {
                extraLarge
                large
                medium
              }
              startDate {
                year
                month
                day
              }
              staff(sort: RELEVANCE) {
                edges {
                  role
                  node {
                    name {
                      full
                    }
                  }
                }
              }
              format
              genres
            }
          }
        }
        """
        
        let payload: [String: Any] = [
            "query": graphqlQuery,
            "variables": ["search": query]
        ]
        
        guard let postData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw AniListError.decodingError(NSError(domain: "AniListService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct JSON payload"]))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = postData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw AniListError.networkError(NSError(domain: "AniListService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Server responded with status code \(httpResponse.statusCode)"]))
        }
        
        do {
            let result = try JSONDecoder().decode(AniListResponse.self, from: data)
            let list = result.data.Page.media
            
            // 3. Save to Cache on successful result
            searchCache[cleanedQuery] = list
            return list
        } catch {
            Logger.shared.log("AniList Decoding Error: \(error.localizedDescription)", category: "Metadata", type: .error)
            throw AniListError.decodingError(error)
        }
    }
}
