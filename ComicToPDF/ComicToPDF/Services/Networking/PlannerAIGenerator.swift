import Foundation

class PlannerAIGenerator {
    
    enum AIError: LocalizedError {
        case missingKey(String)
        case invalidResponse
        case networkError(String)
        
        var errorDescription: String? {
            switch self {
            case .missingKey(let vendor): return "Please enter your \(vendor) API Key in Settings."
            case .invalidResponse: return "The AI returned an invalid layout format. Please try again."
            case .networkError(let msg): return "Network Error: \(msg)"
            }
        }
    }
    
    struct AIResponse: Codable {
        let title: String
        let pages: [AIPage]
    }
    
    struct AIPage: Codable {
        let title: String
        let elements: [AIElement]
    }
    
    struct AIElement: Codable {
        let type: String // "text", "rectangle", "circle", "line", "image", "linkZone"
        let x: Double // 0 to 1000 scale
        let y: Double
        let width: Double
        let height: Double
        let colorHex: String?
        let text: String?
        let strokeWidth: Double?
        let targetPageTitle: String?
    }
    
    static func generateProject(from prompt: String, settings: ConversionSettings) async throws -> PlannerProject {
        
        let vendor = settings.aiVendor
        let apiKey: String
        let endpoint: String
        let model: String
        var isAnthropic = false
        var isGeminiNative = false
        
        switch vendor {
        case .openRouter:
            apiKey = settings.openRouterAPIKey
            endpoint = "https://openrouter.ai/api/v1/chat/completions"
            model = "google/gemini-2.5-flash"
        case .openAI:
            apiKey = settings.openAIAPIKey
            endpoint = "https://api.openai.com/v1/chat/completions"
            model = "gpt-4o"
        case .anthropic:
            apiKey = settings.anthropicAPIKey
            endpoint = "https://api.anthropic.com/v1/messages"
            model = "claude-3-5-sonnet-20241022"
            isAnthropic = true
        case .gemini:
            apiKey = settings.geminiAPIKey
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(settings.geminiAPIKey)"
            model = "gemini-2.5-flash"
            isGeminiNative = true
        }
        
        if apiKey.isEmpty {
            throw AIError.missingKey(vendor.rawValue)
        }
        
        let systemPrompt = """
        You are an expert digital planner designer. Return ONLY raw JSON with absolutely no markdown wrapping blocks like ```json.
        Schema:
        {
          "title": "String",
          "pages": [
            {
              "title": "String",
              "elements": [
                {
                  "type": "text|rectangle|circle|line|linkZone",
                  "x": 100.0, // 0 to 1000 scale (Normalized Coordinate System) Top-Left Origin
                  "y": 100.0,
                  "width": 800.0,
                  "height": 50.0,
                  "text": "optional",
                  "colorHex": "#000000",
                  "targetPageTitle": "optional link target EXACT string match"
                }
              ]
            }
          ]
        }
        Generate a comprehensive, beautiful layout containing shapes (lines, borders, trackers) and text. Do not output anything other than JSON.
        """
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if !isGeminiNative {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let requestBody: [String: Any]
        
        if isAnthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            
            requestBody = [
                "model": model,
                "max_tokens": 8000,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
        } else if isGeminiNative {
            requestBody = [
                "systemInstruction": ["parts": [ ["text": systemPrompt] ]],
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["responseMimeType": "application/json"]
            ]
        } else {
            // OpenAI / OpenRouter
            requestBody = [
                "model": model,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt]
                ]
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpStatus = response as? HTTPURLResponse else { throw AIError.networkError("Invalid Response") }
        guard httpStatus.statusCode == 200 else {
            if let errorText = String(data: data, encoding: .utf8) {
                Logger.shared.log("API Error: \(errorText)", category: "AIGenerator", type: .error)
            }
            throw AIError.networkError("HTTP \(httpStatus.statusCode)")
        }
        
        let rawString = String(data: data, encoding: .utf8) ?? ""
        var extractedJSON = ""
        
        if isAnthropic {
            struct AnthropicResponse: Decodable {
                let content: [ContentBlock]
                struct ContentBlock: Decodable { let text: String }
            }
            let res = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            extractedJSON = res.content.first?.text ?? ""
        } else if isGeminiNative {
            struct GeminiResponse: Decodable {
                let candidates: [Candidate]?
                struct Candidate: Decodable { let content: Content }
                struct Content: Decodable { let parts: [Part] }
                struct Part: Decodable { let text: String }
            }
            let res = try JSONDecoder().decode(GeminiResponse.self, from: data)
            extractedJSON = res.candidates?.first?.content.parts.first?.text ?? ""
        } else {
            struct OpenAIResponse: Decodable {
                let choices: [Choice]
                struct Choice: Decodable { let message: Message }
                struct Message: Decodable { let content: String }
            }
            let res = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            extractedJSON = res.choices.first?.message.content ?? ""
        }
        
        extractedJSON = extractedJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if extractedJSON.hasPrefix("```json") {
            extractedJSON = extractedJSON.replacingOccurrences(of: "```json\n", with: "")
            extractedJSON = extractedJSON.replacingOccurrences(of: "```", with: "")
        }
        
        guard let jsonData = extractedJSON.data(using: .utf8) else { throw AIError.invalidResponse }
        let aiProject = try JSONDecoder().decode(AIResponse.self, from: jsonData)
        
        var finalProject = PlannerProject(title: aiProject.title)
        
        var pageTitleToUUID: [String: UUID] = [:]
        for pageConfig in aiProject.pages {
            var newPage = PlannerPage()
            newPage.title = pageConfig.title
            finalProject.pages.append(newPage)
            pageTitleToUUID[pageConfig.title] = newPage.id
        }
        
        for (index, pageConfig) in aiProject.pages.enumerated() {
            var uiElements: [PlannerElement] = []
            for aiElement in pageConfig.elements {
                guard let mappedType = PlannerElement.ElementType(rawValue: aiElement.type) else { continue }
                
                let rect = NormalizedRect(x: aiElement.x, y: aiElement.y, width: aiElement.width, height: aiElement.height)
                var resolvedTarget: UUID? = nil
                if mappedType == .linkZone, let targetPageTitle = aiElement.targetPageTitle {
                    resolvedTarget = pageTitleToUUID[targetPageTitle]
                }
                
                let convertedElement = PlannerElement(
                    type: mappedType,
                    rect: rect,
                    colorHex: aiElement.colorHex ?? "#000000",
                    strokeWidth: CGFloat(aiElement.strokeWidth ?? 2.0),
                    text: aiElement.text,
                    targetPageID: resolvedTarget
                )
                uiElements.append(convertedElement)
            }
            finalProject.pages[index].elements = uiElements
        }
        
        return finalProject
    }
}
