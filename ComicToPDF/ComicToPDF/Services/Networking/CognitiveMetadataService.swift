import Foundation
import UIKit

struct SemanticMetadataResult: Codable {
    let series: String?
    let title: String?
    let issueNumber: String?
    let publisher: String?
    let publicationYear: String?
}

enum CognitiveError: Error, LocalizedError {
    case invalidAPIKey
    case networkError(String)
    case decodingFailed
    case noResponse
    
    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Missing or Invalid OpenAI API Key."
        case .networkError(let msg): return "Network Error: \(msg)"
        case .decodingFailed: return "AI returned an invalid or unparseable JSON structure."
        case .noResponse: return "The AI failed to generate a response."
        }
    }
}

class CognitiveMetadataService {
    static let shared = CognitiveMetadataService()
    
    private init() {}
    
    /// Extracts absolute perfect metadata from a chaotic filename, using the Cover Image as visual ground-truth Context.
    func extractMetadata(filename: String, coverURL: URL?, apiKey: String) async throws -> SemanticMetadataResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CognitiveError.invalidAPIKey }
        
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let promptText = """
        You are an expert Comic Book and Manga librarian. 
        Your job is to clean up completely messy/randomized filenames and extract the TRUE metadata.
        Original filename: "\(filename)"
        
        Guidelines:
        1. If a cover image is provided, rely on the visual text (Series, Issue number, Publisher, Year) as the absolute source of truth.
        2. Clean up scene release tags (e.g. Zone-Empire, c2c, Digital).
        3. Do NOT include issue numbers in the "series" or "title" fields.
        4. "series" should be the main title (e.g. "Batman").
        5. "title" should be the specific story arc or sub-title if present (e.g. "The Court of Owls Part 1"). If it's just a numbered issue, leave `title` null.
        6. Return ONLY a valid JSON dictionary matching this schema exactly:
        {
          "series": "string or null",
          "title": "string or null",
          "issueNumber": "string or null",
          "publisher": "string or null",
          "publicationYear": "string or null"
        }
        """
        
        var messageContent: [[String: Any]] = []
        messageContent.append(["type": "text", "text": promptText])
        
        // Compress Image to save tokens & time
        if let url = coverURL, let base64String = encodeImageToBase64(from: url) {
            messageContent.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(base64String)",
                    "detail": "low" // Low detail uses only ~85 tokens, perfect for text recognition on covers
                ]
            ])
        }
        
        let payload: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                [
                    "role": "user",
                    "content": messageContent
                ]
            ],
            "temperature": 0.1, // Strict factual extraction
            "response_format": ["type": "json_object"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CognitiveError.networkError("Invalid HTTP server response.")
        }
        
        if httpResponse.statusCode == 401 { throw CognitiveError.invalidAPIKey }
        if httpResponse.statusCode != 200 {
            throw CognitiveError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        
        let decoder = JSONDecoder()
        do {
            let aiResult = try decoder.decode(OpenAIResponse.self, from: data)
            guard let content = aiResult.choices.first?.message.content,
                  let contentData = content.data(using: .utf8) else {
                throw CognitiveError.noResponse
            }
            let result = try decoder.decode(SemanticMetadataResult.self, from: contentData)
            return result
        } catch {
            Logger.shared.log("Vision Decoder Error: \(error.localizedDescription)", category: "Network", type: .error)
            throw CognitiveError.decodingFailed
        }
    }
    
    /// Downsamples and compresses the image to a highly efficient JPEG Base64 string
    private func encodeImageToBase64(from url: URL) -> String? {
        var image: UIImage? = nil
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
        } else {
            if let data = try? Data(contentsOf: url) {
                image = UIImage(data: data)
            }
        }
        
        guard let originalImage = image else { return nil }
        
        // Scale down to max 512px dimension (Standard for typical GPT-4o 'Low' detail limit)
        let maxDimension: CGFloat = 512.0
        let size = originalImage.size
        
        var targetSize = size
        if size.width > maxDimension || size.height > maxDimension {
            let ratio = min(maxDimension / size.width, maxDimension / size.height)
            targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // Prevent Retina scaling up
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let renderedImage = renderer.image { _ in
            originalImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        
        // Strong compression (0.6) yields very small payload, fast network
        guard let jpegData = renderedImage.jpegData(compressionQuality: 0.6) else { return nil }
        return jpegData.base64EncodedString()
    }
}
