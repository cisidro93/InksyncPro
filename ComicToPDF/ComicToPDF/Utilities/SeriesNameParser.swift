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
            of: #"^(manga|comic|book)[0-9]+"#,
            with: "",
            options: .regularExpression
        )

        // Replace hyphens, underscores, and ellipsis artifacts with spaces
        s = s.replacingOccurrences(of: #"[-_\.]+"#, with: " ", options: .regularExpression)

        // Remove trailing/leading whitespace
        s = s.trimmingCharacters(in: .whitespaces)

        // Title-case each word
        let titled = s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
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
        let byFolder = Dictionary(grouping: urls) {
            $0.deletingLastPathComponent().lastPathComponent
        }

        return byFolder
            .sorted { $0.key < $1.key }
            .map { folderName, folderURLs in
                let seriesName: String
                if isSourceSiteFolder(folderName) {
                    // Loose files at source-site root — label clearly
                    let siteName = cleanFolderName(folderName)
                    seriesName = siteName.isEmpty ? "Imported Files" : "From \(siteName)"
                } else {
                    let cleaned = cleanFolderName(folderName)
                    seriesName = cleaned.isEmpty ? folderName : cleaned
                }

                // Sort by chapter number, fall back to filename sort
                let sorted = folderURLs.sorted {
                    let a = chapterKey(from: $0.lastPathComponent) ?? $0.lastPathComponent
                    let b = chapterKey(from: $1.lastPathComponent) ?? $1.lastPathComponent
                    return a.localizedStandardCompare(b) == .orderedAscending
                }

                return (seriesName: seriesName, urls: sorted)
            }
    }
}
