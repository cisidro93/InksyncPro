import SwiftUI
import ZIPFoundation

// MARK: - CBZ Table of Contents

/// Parses the folder structure inside a CBZ to produce chapter groups.
/// Convention: CBZ files often nest chapters as sub-folders inside the archive.
struct CBZTableOfContents {
    struct Chapter: Identifiable {
        let id = UUID()
        let title: String
        let firstPageIndex: Int   // absolute index in the flat pages array
        let pageCount: Int
    }

    let chapters: [Chapter]

    /// Build TOC from the sorted pages array extracted during archive open.
    /// Groups pages by their immediate parent folder name.
    /// Build TOC from sorted pages array and optional unzipped directory or raw archive entry paths.
    /// Supports:
    /// 1. EPUB 2 NCX (`toc.ncx`) and EPUB 3 Navigation Document (`nav.xhtml`)
    /// 2. Sub-folder based grouping for CBZ archives
    /// 3. In-flight pattern recognition for flat CBZs (e.g. `c001_p001.jpg` vs `c002_p001.jpg`)
    static func build(
        from pages: [URL],
        unzippedDir: URL? = nil
    ) -> CBZTableOfContents {
        guard !pages.isEmpty else { return CBZTableOfContents(chapters: []) }

        // 1. Try EPUB TOC from unzipped directory if available
        if let dir = unzippedDir {
            if let epubTOC = parseEPUBDirectory(dir, pageCount: pages.count, pages: pages) {
                return epubTOC
            }
        }

        // 2. Attempt folder-based grouping (CBZ standard)
        var folderOrder: [String] = []
        var folderMap: [String: [Int]] = [:]

        for (idx, url) in pages.enumerated() {
            let comps = url.pathComponents
            let folder: String
            if comps.count >= 2 {
                folder = comps[comps.count - 2]
            } else {
                folder = "Chapter 1"
            }
            if folderMap[folder] == nil {
                folderOrder.append(folder)
                folderMap[folder] = []
            }
            folderMap[folder, default: []].append(idx)
        }

        // If multiple folders exist (and not just generic container dirs), build chapters from folders
        let nonGenericFolders = folderOrder.filter {
            let lower = $0.lowercased()
            return lower != "images" && lower != "oebps" && lower != "text" && lower != "meta-inf"
        }
        if nonGenericFolders.count > 1 {
            var chapters: [Chapter] = []
            var runningIndex = 0
            for (i, folder) in nonGenericFolders.enumerated() {
                guard let indices = folderMap[folder], !indices.isEmpty else { continue }
                let title = folder.hasPrefix("Chapter") || folder.hasPrefix("chapter")
                    ? folder
                    : "Chapter \(i + 1): \(folder)"
                chapters.append(Chapter(title: title, firstPageIndex: runningIndex, pageCount: indices.count))
                runningIndex += indices.count
            }
            return CBZTableOfContents(chapters: chapters)
        }

        // 3. Flat CBZ pattern recognition (detecting c001, ch1 in filenames)
        if let patternChapters = detectFilenameChapters(from: pages.map(\.lastPathComponent)) {
            return CBZTableOfContents(chapters: patternChapters)
        }

        // 4. Fallback single chapter
        let chapter = Chapter(title: "Chapter 1", firstPageIndex: 0, pageCount: pages.count)
        return CBZTableOfContents(chapters: [chapter])
    }

    /// Build TOC directly from an in-memory ZIP archive (for ComicImageCache zero-disk extraction)
    static func build(from archive: Archive, sortedEntries: [ZIPFoundation.Entry]) -> CBZTableOfContents {
        guard !sortedEntries.isEmpty else { return CBZTableOfContents(chapters: []) }

        // 1. Check for toc.ncx in the archive
        let ncxCandidates = ["OEBPS/toc.ncx", "toc.ncx", "OPS/toc.ncx"]
        var ncxEntry: ZIPFoundation.Entry?
        for candidate in ncxCandidates {
            if let entry = archive[candidate] {
                ncxEntry = entry
                break
            }
        }
        if ncxEntry == nil {
            ncxEntry = archive.first(where: { $0.path.lowercased().hasSuffix(".ncx") })
        }

        if let entry = ncxEntry {
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            if let text = String(data: data, encoding: .utf8),
               let chapters = parseNCXText(text, totalPages: sortedEntries.count, entryPaths: sortedEntries.map(\.path)) {
                return CBZTableOfContents(chapters: chapters)
            }
        }

        // 2. Check for nav.xhtml in the archive
        let navCandidates = ["OEBPS/nav.xhtml", "nav.xhtml", "OPS/nav.xhtml"]
        var navEntry: ZIPFoundation.Entry?
        for candidate in navCandidates {
            if let entry = archive[candidate] {
                navEntry = entry
                break
            }
        }
        if navEntry == nil {
            navEntry = archive.first(where: { $0.path.lowercased().hasSuffix("nav.xhtml") })
        }

        if let entry = navEntry {
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            if let text = String(data: data, encoding: .utf8),
               let chapters = parseNavText(text, totalPages: sortedEntries.count, entryPaths: sortedEntries.map(\.path)) {
                return CBZTableOfContents(chapters: chapters)
            }
        }

        // 3. Fallback to folder-based grouping from entry paths
        var folderOrder: [String] = []
        var folderMap: [String: [Int]] = [:]
        for (idx, entry) in sortedEntries.enumerated() {
            let comps = entry.path.components(separatedBy: "/")
            let folder: String
            if comps.count >= 2 {
                folder = comps[comps.count - 2]
            } else {
                folder = "Chapter 1"
            }
            if folderMap[folder] == nil {
                folderOrder.append(folder)
                folderMap[folder] = []
            }
            folderMap[folder, default: []].append(idx)
        }

        let nonGenericFolders = folderOrder.filter {
            let lower = $0.lowercased()
            return lower != "images" && lower != "oebps" && lower != "text" && lower != "meta-inf"
        }
        if nonGenericFolders.count > 1 {
            var chapters: [Chapter] = []
            var runningIndex = 0
            for (i, folder) in nonGenericFolders.enumerated() {
                guard let indices = folderMap[folder], !indices.isEmpty else { continue }
                let title = folder.localizedCaseInsensitiveContains("chapter")
                    ? folder
                    : "Chapter \(i + 1): \(folder)"
                chapters.append(Chapter(title: title, firstPageIndex: runningIndex, pageCount: indices.count))
                runningIndex += indices.count
            }
            return CBZTableOfContents(chapters: chapters)
        }

        // 4. Flat archive pattern recognition
        if let patternChapters = detectFilenameChapters(from: sortedEntries.map { ($0.path as NSString).lastPathComponent }) {
            return CBZTableOfContents(chapters: patternChapters)
        }

        return CBZTableOfContents(chapters: [Chapter(title: "Chapter 1", firstPageIndex: 0, pageCount: sortedEntries.count)])
    }

    // MARK: - EPUB Parsing Helpers

    private static func parseEPUBDirectory(_ dir: URL, pageCount: Int, pages: [URL]) -> CBZTableOfContents? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }

        var ncxURL: URL?
        var navURL: URL?
        while let file = enumerator.nextObject() as? URL {
            let name = file.lastPathComponent.lowercased()
            if name == "toc.ncx" || name.hasSuffix(".ncx") {
                ncxURL = file
                break
            } else if name == "nav.xhtml" {
                navURL = file
            }
        }

        if let ncx = ncxURL, let text = try? String(contentsOf: ncx, encoding: .utf8) {
            if let chapters = parseNCXText(text, totalPages: pageCount, entryPaths: pages.map(\.lastPathComponent)) {
                return CBZTableOfContents(chapters: chapters)
            }
        }

        if let nav = navURL, let text = try? String(contentsOf: nav, encoding: .utf8) {
            if let chapters = parseNavText(text, totalPages: pageCount, entryPaths: pages.map(\.lastPathComponent)) {
                return CBZTableOfContents(chapters: chapters)
            }
        }

        return nil
    }

    private static func parseNCXText(_ text: String, totalPages: Int, entryPaths: [String]? = nil) -> [Chapter]? {
        let pattern = #"(?s)<navPoint[^>]*>.*?<text>(.*?)</text>.*?<content\s+src="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return nil }

        var rawChapters: [(title: String, pageIndex: Int)] = []
        let hasCover = entryPaths?.first?.lowercased().contains("cover") == true

        for match in matches {
            guard let titleRange = Range(match.range(at: 1), in: text),
                  let srcRange = Range(match.range(at: 2), in: text) else { continue }
            let title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            let src = String(text[srcRange])

            var resolvedIndex: Int? = nil
            if src.lowercased().contains("cover") {
                resolvedIndex = 0
            } else if let numMatch = src.range(of: #"(?:page_?|p)(\d+)"#, options: .regularExpression) {
                let numStr = src[numMatch].replacingOccurrences(of: #"page_?|p"#, with: "", options: [.regularExpression, .caseInsensitive])
                if let num = Int(numStr), num >= 1 {
                    resolvedIndex = hasCover ? num : num - 1
                }
            }

            if let idx = resolvedIndex {
                let clamped = max(0, min(idx, max(0, totalPages - 1)))
                rawChapters.append((title: title, pageIndex: clamped))
            }
        }

        guard rawChapters.count > 1 else { return nil }

        return rawChapters.enumerated().map { idx, ch in
            let end = idx + 1 < rawChapters.count ? rawChapters[idx + 1].pageIndex : totalPages
            let count = max(1, end - ch.pageIndex)
            return Chapter(title: ch.title, firstPageIndex: ch.pageIndex, pageCount: count)
        }
    }

    private static func parseNavText(_ text: String, totalPages: Int, entryPaths: [String]? = nil) -> [Chapter]? {
        let pattern = #"(?s)<li[^>]*>\s*<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return nil }

        var rawChapters: [(title: String, pageIndex: Int)] = []
        let hasCover = entryPaths?.first?.lowercased().contains("cover") == true

        for match in matches {
            guard let srcRange = Range(match.range(at: 1), in: text),
                  let titleRange = Range(match.range(at: 2), in: text) else { continue }
            let title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            let src = String(text[srcRange])

            var resolvedIndex: Int? = nil
            if src.lowercased().contains("cover") {
                resolvedIndex = 0
            } else if let numMatch = src.range(of: #"(?:page_?|p)(\d+)"#, options: .regularExpression) {
                let numStr = src[numMatch].replacingOccurrences(of: #"page_?|p"#, with: "", options: [.regularExpression, .caseInsensitive])
                if let num = Int(numStr), num >= 1 {
                    resolvedIndex = hasCover ? num : num - 1
                }
            }

            if let idx = resolvedIndex {
                let clamped = max(0, min(idx, max(0, totalPages - 1)))
                rawChapters.append((title: title, pageIndex: clamped))
            }
        }

        guard rawChapters.count > 1 else { return nil }

        return rawChapters.enumerated().map { idx, ch in
            let end = idx + 1 < rawChapters.count ? rawChapters[idx + 1].pageIndex : totalPages
            let count = max(1, end - ch.pageIndex)
            return Chapter(title: ch.title, firstPageIndex: ch.pageIndex, pageCount: count)
        }
    }

    private static func detectFilenameChapters(from filenames: [String]) -> [Chapter]? {
        guard filenames.count >= 4 else { return nil }
        let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:c|ch|chapter|stage)\.?\s*(\d+)"#, options: [])
        guard let reg = regex else { return nil }

        var chapterStarts: [(chapterNum: Int, firstIndex: Int)] = []
        var lastNum: Int? = nil

        for (idx, name) in filenames.enumerated() {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = reg.firstMatch(in: name, options: [], range: range),
               let numRange = Range(match.range(at: 1), in: name),
               let num = Int(name[numRange]) {
                if num != lastNum {
                    chapterStarts.append((chapterNum: num, firstIndex: idx))
                    lastNum = num
                }
            }
        }

        guard chapterStarts.count > 1 else { return nil }

        return chapterStarts.enumerated().map { idx, item in
            let end = idx + 1 < chapterStarts.count ? chapterStarts[idx + 1].firstIndex : filenames.count
            let count = max(1, end - item.firstIndex)
            return Chapter(title: "Chapter \(item.chapterNum)", firstPageIndex: item.firstIndex, pageCount: count)
        }
    }
}

// MARK: - TOC Sheet View

struct ReaderTOCSheet: View {
    let toc: CBZTableOfContents
    @Binding var currentPageIndex: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if toc.chapters.count <= 1 {
                    ContentUnavailableView(
                        "No Chapters Found",
                        systemImage: "list.bullet.rectangle",
                        description: Text("This book has a single flat chapter. Use the scrubber to navigate.")
                    )
                } else {
                    List(toc.chapters) { chapter in
                        Button {
                            currentPageIndex = chapter.firstPageIndex
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(chapter.pageCount) pages")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if currentPageIndex >= chapter.firstPageIndex &&
                                   currentPageIndex < chapter.firstPageIndex + chapter.pageCount {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(Color.orange)
                                        .font(.system(size: 13))
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Table of Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }
}

// MARK: - CBR Support

/// CBR files are RAR archives.
/// Full native RAR extraction is powered by Unrar.swift (wrapping the official libunrar C++ source).
struct CBRSupportChecker {
    static func isCBR(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "cbr" || ext == "rar"
    }
    /// Returns true when CBR support has been compiled in (Unrar.swift linked).
    static let isSupported: Bool = true
}
