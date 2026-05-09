import SwiftUI
import PDFKit

// ============================================================================
// ReaderSearchView
// ============================================================================
// Full-text search sheet for PDF documents.
// Wraps PDFKit's native findString API and drives PDFView selection/scrolling.
// ============================================================================

struct ReaderSearchView: View {
    let document: PDFDocument
    let pdfView: PDFView

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PDFSelection] = []
    @State private var currentResultIndex = 0
    @State private var isSearching = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Search Bar ───────────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search in document…", text: $query)
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

                // ── Result Navigation ────────────────────────────────────────
                if !results.isEmpty {
                    HStack(spacing: 16) {
                        Text("\(currentResultIndex + 1) of \(results.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            currentResultIndex = max(0, currentResultIndex - 1)
                            scrollToCurrentResult()
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .disabled(currentResultIndex == 0)

                        Button {
                            currentResultIndex = min(results.count - 1, currentResultIndex + 1)
                            scrollToCurrentResult()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .disabled(currentResultIndex == results.count - 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // ── Result List ──────────────────────────────────────────────
                if isSearching {
                    Spacer()
                    ProgressView("Searching…")
                    Spacer()
                } else if results.isEmpty && !query.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No results for \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(results.indices, id: \.self) { idx in
                        Button {
                            currentResultIndex = idx
                            scrollToCurrentResult()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let page = results[idx].pages.first,
                                   let label = page.label {
                                    Text("Page \(label)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(snippet(for: results[idx]))
                                    .font(.body)
                                    .lineLimit(2)
                                    .foregroundStyle(idx == currentResultIndex ? Color.orange : Color.primary)
                            }
                        }
                        .listRowBackground(idx == currentResultIndex
                            ? Color.orange.opacity(0.08)
                            : Color.clear)
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

    // MARK: - Search

    private func runSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        results = []
        currentResultIndex = 0
        fieldFocused = false

        Task.detached(priority: .userInitiated) {
            // PDFDocument.findString is synchronous but fast for most documents.
            let found = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            await MainActor.run {
                self.results = found
                self.isSearching = false
                if !found.isEmpty { self.scrollToCurrentResult() }
            }
        }
    }

    private func scrollToCurrentResult() {
        guard currentResultIndex < results.count else { return }
        let sel = results[currentResultIndex]
        // Reset all match colours, then highlight current
        document.findString(query, withOptions: [.caseInsensitive]).forEach {
            $0.color = .systemYellow.withAlphaComponent(0.4)
        }
        sel.color = .systemOrange
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    // MARK: - Snippet Extraction

    private func snippet(for selection: PDFSelection) -> String {
        guard let str = selection.string else { return "" }
        if let page = selection.pages.first,
           let full = page.string,
           let range = full.range(of: str, options: [.caseInsensitive, .diacriticInsensitive]) {
            let lower = full.index(range.lowerBound, offsetBy: -30, limitedBy: full.startIndex) ?? full.startIndex
            let upper = full.index(range.upperBound, offsetBy:  60, limitedBy: full.endIndex)   ?? full.endIndex
            return "…\(String(full[lower..<upper]))…"
        }
        return str
    }
}
