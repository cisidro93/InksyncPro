import Foundation

enum SeriesNameParser {

    // MARK: - Series Name Cleaning

    /// Converts raw folder names to clean series titles.
    ///
    /// Examples:
    ///   "manga544blame"            → "Blame"
    ///   "manga723chainsaw-man"     → "Chainsaw Man"
    ///   "manga7583miraculous-la...hat-noir" → "Miraculous La Hat Noir"
    ///   "manga1063dragon-ball"     → "Dragon Ball"
    ///   "en.mangapill"             → "Mangapill"  (source-site fallback)
    ///
    static func cleanFolderName(_ raw: String) -> String {
        var s = raw

        // Strip source-site prefixes: "en.", "multi.", "com."
        s = s.replacingOccurrences(
            of: #"^(en\.|multi\.|com\.)"#,
            with: "",
            options: .regularExpression
        )

        // Strip series-folder numeric ID prefix: "manga544", "manga1063", etc.
        s = s.replacingOccurrences(
            of: #"(?i)^(manga|comic|book)[0-9]+"#,
            with: "",
            options: .regularExpression
        )

        // Strip trailing volume/chapter/issue tags (e.g., "Batman Vol 1" -> "Batman")
        // This ensures volume subfolders all group into the same base series name!
        s = s.replacingOccurrences(
            of: #"(?i)\s*(v|vol|volume|ch|chapter|issue|book|part)\.?\s*\d+(\.\d+)?\s*$"#,
            with: "",
            options: .regularExpression
        )

        // Replace hyphens, underscores, and ellipsis artifacts with spaces
        s = s.replacingOccurrences(of: #"[-_\.]+"#, with: " ", options: .regularExpression)

        // Remove trailing/leading whitespace
        s = s.trimmingCharacters(in: .whitespaces)

        // Title-case gently: Uppercase first letter of each word but preserve existing inner caps (e.g., "DC")
        let titled = s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")

        return titled.isEmpty ? raw : titled
    }

    // MARK: - Chapter Number Extraction

    /// Extracts the human-readable chapter number from download-site filenames.
    ///
    /// Examples:
    ///   "chapters544-10065000b...-65.cbz"  → "65"
    ///   "chapters544-10001000b...-1.cbz"   → "1"
    ///   "some-random-name.cbz"             → nil
    ///
    static func chapterKey(from filename: String) -> String? {
        // Match the trailing "-{number}.{extension}" pattern
        let pattern = #"-(\d+)\.[a-zA-Z0-9]+$"#
        guard let range = filename.range(of: pattern, options: .regularExpression),
              let numRange = filename[range].range(of: #"\d+"#, options: .regularExpression)
        else { return nil }
        return String(filename[range][numRange])
    }

    // MARK: - Source-Site Detection

    /// Returns true for source-site container folders that should not
    /// themselves be treated as series names.
    ///
    /// Examples:
    ///   "en.mangapill"       → true
    ///   "multi.mangadex"     → true
    ///   "manga544blame"      → false
    ///
    static func isSourceSiteFolder(_ name: String) -> Bool {
        let pattern = #"^(en\.|multi\.|com\.)"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Series Grouping

    /// Groups a flat list of URLs into series groups using parent folder name.
    ///
    /// Handles three cases:
    ///   1. Normal: files inside a named series subfolder → group by that folder
    ///   2. Source-site root: loose files directly in en.sitename/ with no
    ///      series subfolder → group under a "From {SiteName}" series name
    ///   3. Mixed: some files in subfolders, some at root → handled separately
    ///
    static func groupIntoSeries(_ urls: [URL]) -> [(seriesName: String, urls: [URL])] {
        let genericFolders: Set<String> = [
            "downloads", "inbox", "tmp", "temp", "comics", "documents", "desktop", "manga", 
            "antigravity inksyncpro inbox", "inksyncpro inbox", "inksyncpro"
        ]

        let bySeries = Dictionary(grouping: urls) { url -> String in
            let filename = url.lastPathComponent
            let folderName = url.deletingLastPathComponent().lastPathComponent
            
            // 1. Is the folder a generic OS or user container?
            let isGenericFolder = genericFolders.contains(folderName.lowercased()) 
                || folderName.lowercased().contains("inbox")
                || folderName.hasPrefix("Folder_Spider_") 
                || folderName.hasPrefix("com.apple")
            
            // 2. What does the file name itself tell us?
            let detection = SeriesNameDetector.detect(from: filename)
            
            // 3. Fallback priority selection
            if detection.confidence == .low && !isGenericFolder && !isSourceSiteFolder(folderName) {
                // Filename is ambiguous (e.g. "01.cbz") AND the folder name is explicitly structured (e.g. "One Piece")
                let cleaned = cleanFolderName(folderName)
                return cleaned.isEmpty ? cleanFolderName(detection.seriesName) : cleaned
            }
            
            // Use the smart filename detection.
            let detectedName = cleanFolderName(detection.seriesName)
            if detectedName.isEmpty || isSourceSiteFolder(detectedName) {
                return !isGenericFolder ? cleanFolderName(folderName) : "Imported Files"
            }
            
            return detectedName
        }

        return bySeries
            .sorted { $0.key < $1.key }
            .map { seriesName, folderURLs in
                // Sort the URLs inside the series by chapter number
                let sorted = folderURLs.sorted {
                    let a = chapterKey(from: $0.lastPathComponent) ?? $0.lastPathComponent
                    let b = chapterKey(from: $1.lastPathComponent) ?? $1.lastPathComponent
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
                return (seriesName: seriesName, urls: sorted)
            }
    }
}
