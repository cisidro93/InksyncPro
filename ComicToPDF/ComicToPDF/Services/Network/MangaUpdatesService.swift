import Foundation

enum MangaUpdatesError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case noResults
    case loginFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid MangaUpdates API endpoint URL."
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingError(let err): return "Failed to parse MangaUpdates response: \(err.localizedDescription)"
        case .noResults: return "No manga matching this query was found on MangaUpdates."
        case .loginFailed(let msg): return "MangaUpdates Login Failed: \(msg)"
        }
    }
}

// MARK: - MangaUpdates API Models

struct MangaUpdatesSearchResponse: Codable {
    let results: [MangaUpdatesSearchResultItem]
}

struct MangaUpdatesSearchResultItem: Codable {
    let record: MangaUpdatesManga
}

struct MangaUpdatesManga: Codable, Identifiable {
    let series_id: Int
    let title: String
    let description: String?
    let image: MangaUpdatesImageModel?
    let type: String?
    let year: String?
    let genres: [MangaUpdatesGenre]?
    
    var id: Int { series_id }
}

struct MangaUpdatesImageModel: Codable {
    let url: MangaUpdatesImageUrlModel?
    let height: Int?
    let width: Int?
}

struct MangaUpdatesImageUrlModel: Codable {
    let original: String?
    let thumb: String?
}

struct MangaUpdatesGenre: Codable {
    let genre: String
}

struct MangaUpdatesSeriesDetails: Codable, Identifiable {
    let series_id: Int
    let title: String
    let description: String?
    let image: MangaUpdatesImageModel?
    let type: String?
    let year: String?
    let genres: [MangaUpdatesGenre]?
    let authors: [MangaUpdatesAuthor]?
    let publishers: [MangaUpdatesPublisher]?
    
    var id: Int { series_id }
}

struct MangaUpdatesAuthor: Codable {
    let name: String
    let type: String // "Author" or "Artist"
}

struct MangaUpdatesPublisher: Codable {
    let publisher_name: String
    let type: String // "Original" or "English"
}

struct MangaUpdatesLoginResponse: Codable {
    let status: String
    let reason: String
    let context: MangaUpdatesLoginContext?
}

struct MangaUpdatesLoginContext: Codable {
    let session_token: String?
}

// MARK: - MangaUpdates Service Actor

actor MangaUpdatesService {
    static let shared = MangaUpdatesService()
    
    private var searchCache: [String: [MangaUpdatesManga]] = [:]
    private var detailsCache: [Int: MangaUpdatesSeriesDetails] = [:]
    private var cachedToken: String?
    
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
    
    // Login to MangaUpdates to obtain session token
    func login(username: String, password: String) async throws -> String {
        guard let url = URL(string: "https://api.mangaupdates.com/v1/account/login") else {
            throw MangaUpdatesError.invalidURL
        }
        
        let payload = [
            "username": username,
            "password": password
        ]
        
        guard let postData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw MangaUpdatesError.decodingError(NSError(domain: "MangaUpdatesService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct JSON payload"]))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = postData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                throw MangaUpdatesError.loginFailed("Invalid credentials")
            } else if httpResponse.statusCode != 200 {
                throw MangaUpdatesError.loginFailed("Server responded with code \(httpResponse.statusCode)")
            }
        }
        
        do {
            let result = try JSONDecoder().decode(MangaUpdatesLoginResponse.self, from: data)
            if let token = result.context?.session_token {
                self.cachedToken = token
                return token
            } else {
                throw MangaUpdatesError.loginFailed("Session token missing from response context")
            }
        } catch {
            throw MangaUpdatesError.decodingError(error)
        }
    }
    
    // Helper to get authenticated headers (or login if credentials provided but token is empty)
    private func getHeaders(username: String?, password: String?) async -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "InksyncPro/1.0"
        ]
        
        guard let user = username, !user.isEmpty,
              let pass = password, !pass.isEmpty else {
            if let token = cachedToken {
                headers["Authorization"] = "Bearer \(token)"
            }
            return headers
        }
        
        if let token = cachedToken {
            headers["Authorization"] = "Bearer \(token)"
            return headers
        }
        
        // Try logging in to get the token
        do {
            let token = try await login(username: user, password: pass)
            headers["Authorization"] = "Bearer \(token)"
        } catch {
            Logger.shared.log("MangaUpdates auto-login failed: \(error.localizedDescription)", category: "Metadata", type: .error)
        }
        return headers
    }
    
    // Search Manga
    func searchManga(query: String, username: String? = nil, password: String? = nil) async throws -> [MangaUpdatesManga] {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanedQuery.isEmpty else { return [] }
        
        if let cached = searchCache[cleanedQuery] {
            Logger.shared.log("MangaUpdates Cache Hit for query: '\(cleanedQuery)'", category: "Metadata", type: .info)
            return cached
        }
        
        await throttle()
        
        guard let url = URL(string: "https://api.mangaupdates.com/v1/series/search") else {
            throw MangaUpdatesError.invalidURL
        }
        
        let payload: [String: Any] = [
            "search": query,
            "page": 1,
            "perpage": 20
        ]
        
        guard let postData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw MangaUpdatesError.decodingError(NSError(domain: "MangaUpdatesService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct JSON payload"]))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let headers = await getHeaders(username: username, password: password)
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        request.httpBody = postData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw MangaUpdatesError.networkError(NSError(domain: "MangaUpdatesService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Server responded with status code \(httpResponse.statusCode)"]))
        }
        
        do {
            let result = try JSONDecoder().decode(MangaUpdatesSearchResponse.self, from: data)
            let list = result.results.map { $0.record }
            searchCache[cleanedQuery] = list
            return list
        } catch {
            Logger.shared.log("MangaUpdates Decoding Error: \(error.localizedDescription)", category: "Metadata", type: .error)
            throw MangaUpdatesError.decodingError(error)
        }
    }
    
    // Get Details
    func getSeries(id: Int, username: String? = nil, password: String? = nil) async throws -> MangaUpdatesSeriesDetails {
        if let cached = detailsCache[id] {
            return cached
        }
        
        await throttle()
        
        guard let url = URL(string: "https://api.mangaupdates.com/v1/series/\(id)") else {
            throw MangaUpdatesError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let headers = await getHeaders(username: username, password: password)
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw MangaUpdatesError.networkError(NSError(domain: "MangaUpdatesService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Server responded with status code \(httpResponse.statusCode)"]))
        }
        
        do {
            let details = try JSONDecoder().decode(MangaUpdatesSeriesDetails.self, from: data)
            detailsCache[id] = details
            return details
        } catch {
            Logger.shared.log("MangaUpdates Details Decoding Error: \(error.localizedDescription)", category: "Metadata", type: .error)
            throw MangaUpdatesError.decodingError(error)
        }
    }
    
    // Credentials Verification for Settings View
    func validateCredentials(username: String, password: String) async -> Bool {
        do {
            let _ = try await login(username: username, password: password)
            return true
        } catch {
            return false
        }
    }
}
