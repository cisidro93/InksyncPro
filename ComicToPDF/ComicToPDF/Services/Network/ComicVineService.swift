import Foundation
import UIKit

// MARK: - API Models
struct CVResponse: Codable {
    let results: [CVIssue]
}

struct CVIssue: Codable, Identifiable {
    let id: Int
    let name: String?
    let issue_number: String?
    let cover_date: String?
    let volume: CVVolume?
    let image: CVImage?
    let description: String?
    
    // Computed helper for display
    var fullTitle: String {
        let volName = volume?.name ?? "Unknown Series"
        let num = issue_number ?? "?"
        return "\(volName) #\(num)"
    }
}

struct CVVolume: Codable {
    let name: String
}

struct CVImage: Codable {
    let small_url: String // For list
    let original_url: String // For high-res cover
}

// MARK: - Service Class
class ComicVineService: ObservableObject {
    // ⚠️ Replace with your key for testing, or make this a user setting
    @Published var apiKey: String = "" 
    
    private let baseURL = "https://comicvine.gamespot.com/api"
    
    // Search for a comic (e.g. "Batman 50")
    func searchIssues(query: String) async throws -> [CVIssue] {
        guard !apiKey.isEmpty else { throw NSError(domain: "ComicVine", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Key Missing"]) }
        
        // ComicVine requires a unique User-Agent
        var request = URLRequest(url: URL(string: "\(baseURL)/search/?api_key=\(apiKey)&format=json&resources=issue&query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!)
        request.setValue("InksyncPro-App/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CVResponse.self, from: data)
        return response.results
    }
    
    // Download the cover image
    func fetchCoverImage(url: String) async throws -> UIImage {
        guard let imageURL = URL(string: url) else { throw NSError(domain: "Image", code: 400, userInfo: [:]) }
        let (data, _) = try await URLSession.shared.data(from: imageURL)
        if let image = UIImage(data: data) {
            return image
        } else {
            throw NSError(domain: "Image", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid Image Data"])
        }
    }
}
