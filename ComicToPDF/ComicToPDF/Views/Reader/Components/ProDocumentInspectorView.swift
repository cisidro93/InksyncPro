import SwiftUI
import PDFKit

/// 4-Tab Inspector Panel for Pro PDF Reader (Outline TOC, Bookmarks, Annotations, Search)
struct ProDocumentInspectorView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    let currentPageIndex: Int
    var onJumpToPage: (Int) -> Void
    var onDismiss: () -> Void

    @State private var selectedTab: InspectorTab = .outline
    @State private var searchQuery: String = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var isSearching = false

    enum InspectorTab: String, CaseIterable, Identifiable {
        case outline = "Outline"
        case bookmarks = "Bookmarks"
        case annotations = "Highlights"
        case search = "Search"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .outline: return "list.bullet.indent"
            case .bookmarks: return "bookmark.fill"
            case .annotations: return "highlighter"
            case .search: return "magnifyingglass"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented Tab Bar
                HStack(spacing: 0) {
                    ForEach(InspectorTab.allCases) { tab in
                        Button(action: {
                            HapticEngine.light()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTab = tab
                            }
                        }) {
                            VStack(spacing: 6) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(selectedTab == tab ? .inkGreen : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                selectedTab == tab ? Color.inkGreen.opacity(0.12) : Color.clear
                            )
                        }
                    }
                }
                .background(Theme.surface)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.white.opacity(0.1)),
                    alignment: .bottom
                )

                // Tab Contents
                Group {
                    switch selectedTab {
                    case .outline:
                        outlineSection
                    case .bookmarks:
                        bookmarksSection
                    case .annotations:
                        annotationsSection
                    case .search:
                        searchSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Document Structure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onDismiss()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.inkGreen)
                }
            }
            .background(Color.inkBackground)
        }
    }

    // MARK: - 1. Outline (TOC) Section
    private var outlineSection: some View {
        Group {
            if let outlineRoot = pdfDocument?.outlineRoot, outlineRoot.numberOfChildren > 0 {
                List {
                    OutlineNodeRow(node: outlineRoot, onSelect: { pageIdx in
                        onJumpToPage(pageIdx)
                        onDismiss()
                    })
                }
                .listStyle(.plain)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 38, weight: .light))
                        .foregroundColor(Theme.textTertiary)
                    Text("No Table of Contents")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                    Text("This document does not contain an embedded PDF outline tree.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    // MARK: - 2. Bookmarks Section
    private var bookmarksSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Page Bookmarks")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.text)
                Spacer()
                Button(action: {
                    HapticEngine.medium()
                    // Toggle bookmark for current page
                }) {
                    Label("Bookmark Page \(currentPageIndex + 1)", systemImage: "bookmark.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.inkGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.inkGreen.opacity(0.15))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Theme.textTertiary)
                Text("No Pinned Bookmarks")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()
        }
    }

    // MARK: - 3. Annotations Section
    private var annotationsSection: some View {
        let annotations = AnnotationStore.shared.annotations(for: pdf.id)
        return Group {
            if annotations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(Theme.textTertiary)
                    Text("No Highlights or Notes")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    Text("Selected text and notes will appear here for study review.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
            } else {
                List(annotations) { ann in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(Color(hex: ann.colorHex ?? "#FFD600"))
                                .frame(width: 10, height: 10)
                            Text("Page \(ann.pageIndex + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                            Text(ann.createdAt.formatted(date: .numeric, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                        }

                        if let text = ann.selectedText, !text.isEmpty {
                            Text("\"\(text)\"")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.text)
                                .lineLimit(3)
                        }

                        if let note = ann.noteText, !note.isEmpty {
                            Text("Note: \(note)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.inkGreen)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onJumpToPage(ann.pageIndex)
                        onDismiss()
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 4. Full-Text Search Section
    private var searchSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textTertiary)
                TextField("Search text inside PDF...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.text)
                    .onSubmit {
                        performPDFSearch()
                    }
                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                        searchResults.removeAll()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if isSearching {
                ProgressView("Searching document...")
                    .font(.system(size: 13))
                    .padding()
                Spacer()
            } else if searchResults.isEmpty && !searchQuery.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.textTertiary)
                    Text("No Matches Found")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.top, 32)
                Spacer()
            } else {
                List(searchResults.indices, id: \.self) { idx in
                    let selection = searchResults[idx]
                    if let page = selection.pages.first, let doc = pdfDocument {
                        let pageIdx = doc.index(for: page)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Page \(pageIdx + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.inkGreen)
                                Spacer()
                            }
                            Text(selection.string ?? "")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.text)
                                .lineLimit(2)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onJumpToPage(pageIdx)
                            onDismiss()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func performPDFSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = pdfDocument, !query.isEmpty else { return }
        isSearching = true
        searchResults.removeAll()

        Task.detached(priority: .userInitiated) {
            let matches = doc.findString(query, withOptions: [.caseInsensitive])
            await MainActor.run {
                self.searchResults = matches
                self.isSearching = false
            }
        }
    }
}

/// Recursive Outline Node Row Component for nested PDF Table of Contents
private struct OutlineNodeRow: View {
    let node: PDFOutline
    var onSelect: (Int) -> Void

    var body: some View {
        ForEach(0..<node.numberOfChildren, id: \.self) { index in
            if let child = node.child(at: index) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(child.label ?? "Untitled Section")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.text)
                        Spacer()
                        if let destination = child.destination, let page = destination.page, let doc = page.document {
                            let pageIndex = doc.index(for: page)
                            Text("\(pageIndex + 1)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let destination = child.destination, let page = destination.page, let doc = page.document {
                            let pageIndex = doc.index(for: page)
                            onSelect(pageIndex)
                        }
                    }

                    if child.numberOfChildren > 0 {
                        OutlineNodeRow(node: child, onSelect: onSelect)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}
