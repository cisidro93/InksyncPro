import SwiftUI
import PDFKit

/// 4-Tab Inspector Panel for Pro PDF Reader (Outline TOC, Bookmarks, Annotations, Search)
struct ProDocumentInspectorView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    let currentPageIndex: Int
    var onJumpToPage: (Int) -> Void
    var onJumpToAnnotation: ((Annotation) -> Void)? = nil
    var onDeleteAnnotation: ((Annotation) -> Void)? = nil
    var onDismiss: () -> Void

    @State private var selectedTab: InspectorTab = .outline
    @State private var searchQuery: String = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var unifiedResults: [UnifiedPDFSearchResult] = []
    @State private var isSearching = false
    @State private var annotationPendingDeletion: Annotation? = nil
    @State private var showingDeleteConfirmation = false
    @State private var shareExportItem: String? = nil
    @State private var showShareSheet: Bool = false
    @State private var exportPDFURL: URL? = nil
    @State private var showPDFShareSheet: Bool = false

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

                if selectedTab == .annotations {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                exportHighlightsMarkdown()
                            } label: {
                                Label("Share as Markdown", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                copyReadwiseCSV()
                            } label: {
                                Label("Copy Readwise CSV", systemImage: "tablecells")
                            }

                            if let doc = pdfDocument {
                                Divider()

                                Button {
                                    exportFlattenedPDF(doc: doc)
                                } label: {
                                    Label("Export Flattened PDF", systemImage: "doc.badge.gearshape")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.inkGreen)
                        }
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let text = shareExportItem {
                    ShareSheet(items: [text])
                }
            }
            .sheet(isPresented: $showPDFShareSheet) {
                if let url = exportPDFURL {
                    ShareSheet(items: [url])
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
                    OutlineNodeRow(node: outlineRoot, pdfDocument: pdfDocument, onSelect: { pageIdx in
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
                List {
                    ForEach(annotations) { ann in
                        HStack(alignment: .top, spacing: 10) {
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
                            .contentShape(Rectangle())
                            .onTapGesture {
                                HapticEngine.selection()
                                if let onJumpToAnnotation = onJumpToAnnotation {
                                    onJumpToAnnotation(ann)
                                } else {
                                    onJumpToPage(ann.pageIndex)
                                }
                                onDismiss()
                            }

                            Button {
                                HapticEngine.light()
                                annotationPendingDeletion = ann
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red.opacity(0.7))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete highlight")
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                annotationPendingDeletion = ann
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .alert("Delete Highlight?", isPresented: $showingDeleteConfirmation, presenting: annotationPendingDeletion) { targetAnn in
                    Button("Delete Highlight", role: .destructive) {
                        onDeleteAnnotation?(targetAnn)
                        annotationPendingDeletion = nil
                    }
                    Button("Cancel", role: .cancel) {
                        annotationPendingDeletion = nil
                    }
                } message: { _ in
                    Text("This will permanently remove the highlight from the document and your study notes.")
                }
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
                ProgressView("Searching document & handwritten notes...")
                    .font(.system(size: 13))
                    .padding()
                Spacer()
            } else if unifiedResults.isEmpty && !searchQuery.isEmpty {
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
                List(unifiedResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Page \(result.pageIndex + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.inkGreen)

                            if let badge = result.badge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(result.isHandwritten ? Color.orange.opacity(0.18) : Color.purple.opacity(0.18))
                                    .foregroundColor(result.isHandwritten ? .orange : .purple)
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        Text(result.snippet)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                            .lineLimit(2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onJumpToPage(result.pageIndex)
                        onDismiss()
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
        unifiedResults.removeAll()

        Task {
            // 1. Text search within PDF vector glyphs
            let matches = doc.findString(query, withOptions: [.caseInsensitive])
            var combined: [UnifiedPDFSearchResult] = []
            for sel in matches {
                if let page = sel.pages.first {
                    let pageIdx = doc.index(for: page)
                    if pageIdx != NSNotFound {
                        combined.append(UnifiedPDFSearchResult(
                            pageIndex: pageIdx,
                            snippet: sel.string ?? "",
                            badge: nil,
                            isHandwritten: false
                        ))
                    }
                }
            }

            // 2. Handwritten Ink OCR & Annotation notes search
            let annotations = AnnotationStore.shared.annotations(for: pdf.id)
            let lowerQuery = query.lowercased()
            for ann in annotations {
                if let ocr = ann.drawingOCRText, ocr.lowercased().contains(lowerQuery) {
                    combined.append(UnifiedPDFSearchResult(
                        pageIndex: ann.pageIndex,
                        snippet: ocr,
                        badge: "PENCIL NOTE",
                        isHandwritten: true
                    ))
                } else if let note = ann.noteText, note.lowercased().contains(lowerQuery) {
                    combined.append(UnifiedPDFSearchResult(
                        pageIndex: ann.pageIndex,
                        snippet: note,
                        badge: "NOTE",
                        isHandwritten: false
                    ))
                }
            }

            // Sort results ascending by page number
            combined.sort(by: { $0.pageIndex < $1.pageIndex })

            await MainActor.run {
                self.searchResults = matches
                self.unifiedResults = combined
                self.isSearching = false
            }
        }
    }

    // MARK: - Export Helpers
    private func exportHighlightsMarkdown() {
        let annotations = AnnotationStore.shared.annotations(for: pdf.id)
        guard !annotations.isEmpty else { return }
        let md = HighlightExportService.shared.exportToMarkdown(bookTitle: pdf.name, author: nil, storeAnnotations: annotations)
        shareExportItem = md
        showShareSheet = true
        HapticEngine.selection()
    }
    
    private func copyReadwiseCSV() {
        let annotations = AnnotationStore.shared.annotations(for: pdf.id)
        guard !annotations.isEmpty else { return }
        let csv = HighlightExportService.shared.exportToReadwiseCSV(bookTitle: pdf.name, author: nil, storeAnnotations: annotations)
        UIPasteboard.general.string = csv
        HapticEngine.success()
    }
    
    private func exportFlattenedPDF(doc: PDFDocument) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(pdf.name) (Flattened).pdf")
        do {
            _ = try PDFAnnotationSyncBridge.shared.generateFlattenedPDF(from: doc, for: pdf.id, saveTo: tempURL)
            exportPDFURL = tempURL
            showPDFShareSheet = true
            HapticEngine.success()
        } catch {
            Logger.shared.log("Failed to generate flattened PDF: \(error.localizedDescription)", category: "PDF", type: .error)
            HapticEngine.error()
        }
    }
}

/// Unified search result item covering PDF vector text, OCR handwriting, and margin notes
struct UnifiedPDFSearchResult: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: String
    let badge: String?
    let isHandwritten: Bool
}

/// Recursive Outline Node Row Component for nested PDF Table of Contents
private struct OutlineNodeRow: View {
    let node: PDFOutline
    let pdfDocument: PDFDocument?
    var onSelect: (Int) -> Void

    private func targetPageIndex(for child: PDFOutline) -> Int? {
        if let dest = child.destination {
            if let page = dest.page, let doc = pdfDocument ?? page.document {
                let idx = doc.index(for: page)
                if idx != NSNotFound { return idx }
            }
        }
        if let action = child.action as? PDFActionGoTo {
            let dest = action.destination
            if let page = dest.page, let doc = pdfDocument ?? page.document {
                let idx = doc.index(for: page)
                if idx != NSNotFound { return idx }
            }
        }
        if let label = child.label {
            let components = label.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let lastNum = components.last, let pageNum = Int(lastNum), pageNum > 0, pageNum <= (pdfDocument?.pageCount ?? 0) {
                return pageNum - 1
            }
        }
        return nil
    }

    var body: some View {
        ForEach(0..<node.numberOfChildren, id: \.self) { index in
            if let child = node.child(at: index) {
                let resolvedPageIndex = targetPageIndex(for: child)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(child.label ?? "Untitled Section")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.text)
                        Spacer()
                        if let pageIndex = resolvedPageIndex {
                            Text("\(pageIndex + 1)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let pageIndex = resolvedPageIndex {
                            onSelect(pageIndex)
                        }
                    }

                    if child.numberOfChildren > 0 {
                        OutlineNodeRow(node: child, pdfDocument: pdfDocument, onSelect: onSelect)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

// MARK: - ShareSheet UIKit Bridge
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
