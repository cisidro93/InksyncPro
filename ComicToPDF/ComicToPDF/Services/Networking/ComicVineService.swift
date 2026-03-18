import Foundation
import UIKit

enum ComicVineError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case invalidAPIKey
    case rateLimited
    case noResults
}

struct ComicVineResult: Codable {
    let results: [ComicVineVolume]
}

struct ComicVineVolume: Codable, Identifiable {
    let id: Int
    let name: String
    let start_year: String?
    let publisher: ComicVinePublisher?
    let image: ComicVineImage?
    let count_of_issues: Int?
}

struct ComicVinePublisher: Codable {
    let name: String
}

struct ComicVineImage: Codable {
    let icon_url: String?
    let medium_url: String?
    let original_url: String?
}

class ComicVineService {
    static let shared = ComicVineService()
    
    // Rate Limiting: 1 request per second
    private var lastRequestTime: Date = Date.distantPast
    
    private init() {}
    
    // Validate API Key by making a lightweight request
    func validateAPIKey(_ key: String) async -> Bool {
        // We'll search for "Batman" as a test
        let urlString = "https://comicvine.gamespot.com/api/search/?api_key=\(key)&format=json&query=Batman&resources=volume&limit=1"
        guard let url = URL(string: urlString) else { return false }
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
        } catch {
            Logger.shared.log("API Key Validation error: \(error.localizedDescription)", category: "Metadata", type: .error)
        }
        return false
    }
    
    private func waitForRateLimit() async {
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastRequestTime)
        if timeSinceLast < 1.1 { // Buffer slightly over 1s
            let waitTime = 1.1 - timeSinceLast
             try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
    
    func searchVolumes(query: String, apiKey: String) async throws -> [ComicVineVolume] {
        await waitForRateLimit()
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
             throw ComicVineError.invalidURL
        }
        
        let urlString = "https://comicvine.gamespot.com/api/search/?api_key=\(apiKey)&format=json&query=\(encodedQuery)&resources=volume&limit=20"
        
        guard let url = URL(string: urlString) else { throw ComicVineError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 { throw ComicVineError.invalidAPIKey }
            if httpResponse.statusCode == 420 { throw ComicVineError.rateLimited }
            if httpResponse.statusCode != 200 { throw ComicVineError.networkError(NSError(domain: "", code: httpResponse.statusCode, userInfo: nil)) }
        }
        
        do {
            let result = try JSONDecoder().decode(ComicVineResult.self, from: data)
            return result.results
        } catch {
            Logger.shared.log("Search Decoding Error: \(error.localizedDescription)", category: "Metadata", type: .error)
            throw ComicVineError.decodingError(error)
        }
    }
    
    // MARK: - Detailed Issue Fetch
    
    // Find specific issue in a volume
    func getIssue(volumeID: Int, issueNumber: String, apiKey: String) async throws -> ComicVineIssueDetails? {
        await waitForRateLimit()
        
        let urlString = "https://comicvine.gamespot.com/api/issues/?api_key=\(apiKey)&format=json&filter=volume:\(volumeID),issue_number:\(issueNumber)&limit=1"
        guard let url = URL(string: urlString) else { throw ComicVineError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 { throw ComicVineError.invalidAPIKey }
            if httpResponse.statusCode == 420 { throw ComicVineError.rateLimited }
            if httpResponse.statusCode != 200 { throw ComicVineError.networkError(NSError(domain: "", code: httpResponse.statusCode, userInfo: nil)) }
        }
        
        let result = try JSONDecoder().decode(ComicVineIssueSearchResult.self, from: data)
        return result.results.first
    }

    func getIssueDetails(issueID: Int, apiKey: String) async throws -> ComicVineIssueDetails {
        await waitForRateLimit()
        
        let urlString = "https://comicvine.gamespot.com/api/issue/4000-\(issueID)/?api_key=\(apiKey)&format=json"
        guard let url = URL(string: urlString) else { throw ComicVineError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue("InksyncPro/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 { throw ComicVineError.invalidAPIKey }
            if httpResponse.statusCode == 420 { throw ComicVineError.rateLimited }
            if httpResponse.statusCode != 200 { throw ComicVineError.networkError(NSError(domain: "", code: httpResponse.statusCode, userInfo: nil)) }
        }
        
        do {
            let result = try JSONDecoder().decode(ComicVineIssueResult.self, from: data)
            return result.results
        } catch {
             Logger.shared.log("Issue Decoding Error: \(error.localizedDescription)", category: "Metadata", type: .error)
             throw ComicVineError.decodingError(error)
        }
    }
}

// MARK: - Detailed Models
struct ComicVineIssueResult: Codable {
    let results: ComicVineIssueDetails
}

struct ComicVineIssueSearchResult: Codable {
    let results: [ComicVineIssueDetails]
}

struct ComicVineIssueDetails: Codable {
    let id: Int
    let name: String? // Often nil for issues, used for Story Arcs
    let issue_number: String?
    let volume: ComicVineVolume?
    let description: String? // HTML Summary
    let person_credits: [ComicVinePerson]?
    let image: ComicVineImage?
    let cover_date: String?
}

struct ComicVinePerson: Codable {
    let id: Int?
    let name: String?
    let role: String? // "Writer, Artist"
}
