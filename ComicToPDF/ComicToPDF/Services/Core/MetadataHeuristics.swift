import Foundation

/// A utility struct to encapsulate string matching and metadata inference rules
/// for comic book filenames to ensure consistency between Single Edit and Batch workflows.
struct MetadataHeuristics {
    
    /// Cleans the raw filename to yield a searchable Series/Volume name.
    ///
    /// - Parameter name: The original file name (e.g., "Batman_(2023)_#12.cbz")
    /// - Returns: A cleaned query string (e.g., "Batman")
    static func cleanFilename(_ name: String) -> String {
        var clean = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        
        // Remove underscores and replacing them with spaces
        clean = clean.replacingOccurrences(of: "_", with: " ")
        
        // Remove parenthesis content roughly (e.g. publication years "(2023)")
        if let range = clean.range(of: "\\(.*?\\)", options: .regularExpression) {
             clean.removeSubrange(range)
        }
        
        // Return stripped query
        return clean.trimmingCharacters(in: .whitespaces)
    }
    
    /// Attempts to extract an issue number from the raw filename using regex.
    ///
    /// - Parameter name: The original file name (e.g., "Batman_#12.cbz")
    /// - Returns: The extracted issue number as a String, if found.
    static func extractIssueNumber(from name: String) -> String? {
        // Look for #123 or 123 at the end of parts
        let pattern = "#?(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
            if let range = Range(match.range(at: 1), in: name) {
                return String(name[range])
            }
        }
        return nil
    }
}
