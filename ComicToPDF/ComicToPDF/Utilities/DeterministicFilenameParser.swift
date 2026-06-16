import Foundation

/// Cleanly tokenizes filename strings into Series, Volume, Issue/Chapter, and Title components.
struct DeterministicFilenameParser {
    
    struct ParsedTokens {
        let seriesName: String
        let volume: String?
        let issueNumber: String?
        let title: String?
    }
    
    /// Parses a filename to extract structured components based on delimiters and prefixes.
    /// Supports the canonical format: `[SeriesName] - v[Volume] - c[IssueNumber] - [Title].[ext]`
    /// as well as standard fallback patterns.
    static func parse(filename: String) -> ParsedTokens {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        
        // Strip leading brackets (e.g. scanlation group prefixes like "[MangaStream]")
        let cleaned = base.replacingOccurrences(of: #"^\[.*?\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Split by the canonical " - " separator
        let parts = cleaned.components(separatedBy: " - ")
        
        var seriesName = ""
        var volume: String?
        var issueNumber: String?
        var title: String?
        
        if parts.count == 1 {
            // Single part filename, delegate to heuristics
            let detection = SeriesNameDetector.detect(from: filename)
            seriesName = detection.seriesName
            issueNumber = detection.issueNumberString
            
            // Extract volume if present using regex
            if let volRange = filename.range(of: #"(?i)v(?:ol(?:ume)?)?\.?\s*(\d+(?:\.\d+)?)"#, options: .regularExpression) {
                let sub = filename[volRange]
                if let numRange = sub.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) {
                    volume = String(sub[numRange])
                }
            }
        } else {
            // First part is the Series Name
            seriesName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            
            for i in 1..<parts.count {
                let part = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Volume check (e.g., "v01" or "v2")
                if part.range(of: #"^[vV]\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
                    let numPart = part.dropFirst()
                    volume = String(numPart)
                }
                // Issue/Chapter check (e.g., "c001" or "c99")
                else if part.range(of: #"^[cC]\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
                    let numPart = part.dropFirst()
                    issueNumber = String(numPart)
                }
                // Any other non-prefixed part is considered the Title
                else {
                    if i == parts.count - 1 {
                        title = part
                    } else if seriesName.isEmpty {
                        seriesName = part
                    }
                }
            }
        }
        
        return ParsedTokens(
            seriesName: seriesName.isEmpty ? base : seriesName,
            volume: volume,
            issueNumber: issueNumber,
            title: title
        )
    }
}
