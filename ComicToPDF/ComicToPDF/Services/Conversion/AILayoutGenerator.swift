import Foundation
import UIKit
import CoreGraphics

class AILayoutGenerator {
    
    struct GeneratedLayout: Codable {
        let lines: [LayoutLine]?
        let textBlocks: [LayoutText]?
    }
    
    struct LayoutLine: Codable {
        let startX: CGFloat
        let startY: CGFloat
        let endX: CGFloat
        let endY: CGFloat
    }
    
    struct LayoutText: Codable {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let isBold: Bool?
    }
    
    /// Calls OpenRouter to generate a layout and draws it onto a UIImage of `targetSize`
    static func generateLayout(
        prompt: String,
        vendor: AIVendor,
        apiKey: String,
        targetSize: CGSize = CGSize(width: 850, height: 1100)
    ) async throws -> UIImage {
        
        guard !apiKey.isEmpty else {
            throw NSError(domain: "AILayoutGenerator", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Key is missing."])
        }
        
        // 1. Ask the LLM to write JSON matching our DTO structures for lines and text.
        let systemPrompt = """
        You are an expert UI layout engine for a digital planner app. The page size is \(Int(targetSize.width))x\(Int(targetSize.height)) pixels.
        The user will give you a prompt for a template (e.g., "Weekly workout tracker").
        Respond ONLY with a raw JSON object (with no markdown fences or backticks) defining precisely where to draw lines and text.
        Structure: {"lines": [{"startX": 0, "startY": 100, "endX": 850, "endY": 100}], "textBlocks": [{"text": "Habits", "x": 50, "y": 50, "size": 36, "isBold": true}]}
        Return empty arrays if none are needed. Do not surround with ```json.
        """
        
        var request: URLRequest
        
        switch vendor {
        case .openRouter:
            let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("InksyncPro", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("InksyncPro E-Ink Tool", forHTTPHeaderField: "X-Title")
            
            let body: [String: Any] = [
                "model": "google/gemini-2.5-flash",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt]
                ],
                "response_format": ["type": "json_object"]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
        case .openAI:
            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "model": "gpt-4o",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt]
                ],
                "response_format": ["type": "json_object"]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
        case .anthropic:
            let url = URL(string: "https://api.anthropic.com/v1/messages")!
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "model": "claude-3-5-sonnet-20241022",
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": prompt]
                ],
                "max_tokens": 8192
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
        case .gemini:
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)")!
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["responseMimeType": "application/json"]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown HTTP Error"
            print("API Error: \(errorMsg)")
            throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to generate AI layout. Check your API key or network connection."])
        }
        
        // Parse appropriate vendor response
        let jsonContent: String
        
        switch vendor {
        case .openRouter, .openAI:
            struct OpenAIResponse: Decodable {
                let choices: [Choice]
                struct Choice: Decodable {
                    let message: Message
                    struct Message: Decodable {
                        let content: String
                    }
                }
            }
            let aiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let content = aiResponse.choices.first?.message.content else {
                throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "AI response was empty."])
            }
            jsonContent = content
            
        case .anthropic:
            struct AnthropicResponse: Decodable {
                let content: [ContentBlock]
                struct ContentBlock: Decodable {
                    let text: String
                }
            }
            let aiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            guard let content = aiResponse.content.first?.text else {
                throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Anthropic response was empty."])
            }
            jsonContent = content
            
        case .gemini:
            struct GeminiResponse: Decodable {
                let candidates: [Candidate]
                struct Candidate: Decodable {
                    let content: Content
                    struct Content: Decodable {
                        let parts: [Part]
                        struct Part: Decodable {
                            let text: String
                        }
                    }
                }
            }
            let aiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            guard let content = aiResponse.candidates.first?.content.parts.first?.text else {
                throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Gemini response was empty."])
            }
            jsonContent = content
        }
        
        // Clean markdown backticks just in case the model ignored "no markdown" rule
        var cleanJSON = jsonContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanJSON.hasPrefix("```json") { cleanJSON.removeFirst(7) }
        else if cleanJSON.hasPrefix("```") { cleanJSON.removeFirst(3) }
        if cleanJSON.hasSuffix("```") { cleanJSON.removeLast(3) }
        
        guard let layoutData = cleanJSON.data(using: .utf8) else {
            throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON string."])
        }
        
        let layout = try JSONDecoder().decode(GeneratedLayout.self, from: layoutData)
        
        // 2. Draw the AI instructions to a UIImage
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else {
            throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize graphics context."])
        }
        
        // White Background
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: targetSize))
        
        // Draw Lines
        UIColor.lightGray.setStroke()
        context.setLineWidth(2.0)
        for line in layout.lines ?? [] {
            context.move(to: CGPoint(x: line.startX, y: line.startY))
            context.addLine(to: CGPoint(x: line.endX, y: line.endY))
        }
        context.strokePath()
        
        // Draw Text
        for textBlock in layout.textBlocks ?? [] {
            let weight: UIFont.Weight = (textBlock.isBold == true) ? .bold : .regular
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: textBlock.size, weight: weight),
                .foregroundColor: UIColor.black
            ]
            let string = NSAttributedString(string: textBlock.text, attributes: attrs)
            string.draw(at: CGPoint(x: textBlock.x, y: textBlock.y))
        }
        
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let finalImage = image else {
            throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to capture generated image."])
        }
        
        return finalImage
    }
}
