import Foundation

struct WikiLinkToken: Identifiable, Hashable {
    var id: String { target + "_\(range.location)" }
    let target: String
    let range: NSRange
}

@MainActor
struct WikiLinkParser {
    static let shared = WikiLinkParser()
    
    private let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\]", options: [])
    
    func parseLinks(in text: String) -> [WikiLinkToken] {
        guard let regex = regex else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let targetRange = match.range(at: 1)
            let target = nsText.substring(with: targetRange)
            return WikiLinkToken(target: target, range: match.range(at: 0))
        }
    }
    
    func extractTargetNames(from text: String) -> [String] {
        return parseLinks(in: text).map { $0.target }
    }
}
