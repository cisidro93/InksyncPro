import SwiftUI
import WebKit

// ============================================================================
// EPUBSearchView
// ============================================================================
// Full-text search for the lightweight EPUB reader (EBookReaderView).
// Scans unzipped chapter HTML files directly; no index required.
// On result tap: navigates to the chapter then injects window.find() JS
// so the match is highlighted in-page, matching Apple Books / Kindle UX.
// ============================================================================

struct EPUBSearchResult: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let chapterLabel: String
    let snippet: String
    let matchText: String
}

struct EPUBSearchView: View {
    let spineItems: [EBookMetadata.SpineItem]
    let unzipDir: URL?
    /// Called with (chapterIndex, matchText) when the user taps a result.
    var onNavigate: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [EPUBSearchResult] = []
    @State private var isSearching = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Search Bar ───────────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search in book…", text: $query)
                        .focused($fieldFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { runSearch() }

                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                // ── Results / States ─────────────────────────────────────────
                if isSearching {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else if results.isEmpty && !query.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No results for \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(results) { result in
                        Button {
                            onNavigate(result.chapterIndex, result.matchText)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.chapterLabel)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                HighlightedSnippetText(
                                    text: result.snippet,
                                    highlight: result.matchText
                                )
                                .font(.subheadline)
                                .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if !query.isEmpty {
                        Button("Search") { runSearch() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Search Logic

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let dir = unzipDir else { return }

        isSearching = true
        results = []
        fieldFocused = false

        let spine = spineItems
        Task.detached(priority: .userInitiated) {
            var found: [EPUBSearchResult] = []

            for (idx, item) in spine.enumerated() {
                var fileURL = dir.appendingPathComponent(item.href)
                if !FileManager.default.fileExists(atPath: fileURL.path),
                   let decoded = item.href.removingPercentEncoding {
                    fileURL = dir.appendingPathComponent(decoded)
                }
                guard let rawHTML = (try? String(contentsOf: fileURL, encoding: .utf8))
                               ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1))
                else { continue }

                // Strip HTML tags for clean text matching
                let plainText = rawHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;",  with: "&")
                    .replacingOccurrences(of: "&lt;",   with: "<")
                    .replacingOccurrences(of: "&gt;",   with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                let lower = plainText.lowercased()
                let qLower = q.lowercased()
                var searchFrom = lower.startIndex

                var chapCount = 0
                while let matchRange = lower.range(of: qLower, range: searchFrom..<lower.endIndex) {
                    let start = lower.index(matchRange.lowerBound, offsetBy: -60, limitedBy: lower.startIndex) ?? lower.startIndex
                    let end   = lower.index(matchRange.upperBound,  offsetBy:  80, limitedBy: lower.endIndex)  ?? lower.endIndex
                    let snippet = (start > lower.startIndex ? "…" : "")
                        + String(plainText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                        + (end < lower.endIndex ? "…" : "")

                    found.append(EPUBSearchResult(
                        chapterIndex: idx,
                        chapterLabel: item.label,
                        snippet: snippet,
                        matchText: String(plainText[matchRange])
                    ))

                    chapCount += 1
                    if chapCount >= 4 { break } // max 4 hits per chapter
                    searchFrom = matchRange.upperBound
                }
            }

            await MainActor.run {
                self.results = found
                self.isSearching = false
            }
        }
    }
}

// MARK: - Highlighted Snippet Text
/// Renders the search snippet with the matching portion highlighted in orange.
struct HighlightedSnippetText: View {
    let text: String
    let highlight: String

    var body: some View {
        if let range = text.lowercased().range(of: highlight.lowercased()) {
            let before = String(text[..<range.lowerBound])
            let match = String(text[range])
            let after = String(text[range.upperBound...])
            
            (Text(before) + 
             Text(match).foregroundColor(.orange).fontWeight(.bold) + 
             Text(after))
        } else {
            Text(text)
        }
    }
}
