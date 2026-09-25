import SwiftUI
import SwiftData

// ============================================================
// MARK: - BookHighlightsView
// Dedicated, professional Book Highlights inspection workspace.
// Features executive serif quote cards, glowing color accent bars,
// chapter/page jump badges, attached note callouts, instant search,
// color filtering, and Markdown/Plain-Text export.
// ============================================================
enum AnnotationCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case highlights = "Highlights"
    case notes = "Notes"
    case bookmarks = "Bookmarks"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .highlights: return "highlighter"
        case .notes: return "note.text"
        case .bookmarks: return "bookmark.fill"
        }
    }
}

enum AnnotationSortOption: String, CaseIterable, Identifiable {
    case bookOrder = "Page"
    case recent = "Date"
    case color = "Color"
    
    var id: String { rawValue }
}

struct BookHighlightsView: View {
    let bookID: String
    let bookTitle: String
    var onJumpToHighlight: ((SDAnnotation) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var bookHighlights: [SDAnnotation] = []
    @State private var searchQuery: String = ""
    @State private var selectedColorFilter: String? = nil
    @State private var selectedTagFilter: String? = nil
    @State private var categoryFilter: AnnotationCategoryFilter = .all
    @State private var sortOption: AnnotationSortOption = .bookOrder
    @State private var activeHighlightToEdit: SDAnnotation? = nil
    @State private var highlightToDelete: SDAnnotation? = nil
    @State private var showDeleteConfirmation: Bool = false
    @State private var copiedHighlightID: UUID? = nil
    @State private var expandedQuoteIDs: Set<UUID> = []
    @State private var isExporting: Bool = false
    @State private var exportedText: String = ""

    private var targetPDFID: UUID {
        if let actualUUID = UUID(uuidString: bookID) {
            let nbDesc = FetchDescriptor<SDNotebook>(predicate: #Predicate { $0.id == actualUUID })
            if let nb = try? modelContext.fetch(nbDesc).first, let linked = nb.linkedBookID {
                return linked
            }
            return actualUUID
        }
        let hash = abs(bookID.hashValue)
        let uuidStr = String(format: "00000000-0000-0000-0000-%012x", hash)
        return UUID(uuidString: uuidStr) ?? UUID()
    }

    private var availableColors: [String] {
        let colors = bookHighlights.compactMap { $0.colorHex }
        return Array(Set(colors)).sorted()
    }

    private var allTags: [String] {
        let tags = bookHighlights.flatMap { $0.tags ?? [] }
        return Array(Set(tags)).sorted()
    }

    private var filteredHighlights: [SDAnnotation] {
        var list = bookHighlights

        if let colorFilter = selectedColorFilter {
            list = list.filter { ($0.colorHex ?? "").localizedCaseInsensitiveContains(colorFilter) }
        }

        if let tagFilter = selectedTagFilter {
            list = list.filter { $0.tags?.contains(tagFilter) ?? false }
        }

        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = searchQuery.lowercased()
            list = list.filter {
                ($0.selectedText?.lowercased().contains(query) ?? false) ||
                ($0.noteText?.lowercased().contains(query) ?? false) ||
                ($0.chapterTitle?.lowercased().contains(query) ?? false) ||
                ($0.tags?.contains(where: { $0.lowercased().contains(query) }) ?? false)
            }
        }

        switch categoryFilter {
        case .all:
            break
        case .highlights:
            list = list.filter { ($0.selectedText != nil && !$0.selectedText!.isEmpty) }
        case .notes:
            list = list.filter { !($0.noteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .bookmarks:
            list = list.filter { $0.adlerianSymbol != nil || ($0.selectedText == nil && $0.noteText == nil) }
        }

        switch sortOption {
        case .bookOrder:
            return list.sorted {
                if $0.pageIndex != $1.pageIndex {
                    return $0.pageIndex < $1.pageIndex
                }
                return $0.createdAt < $1.createdAt
            }
        case .recent:
            return list.sorted { $0.createdAt > $1.createdAt }
        case .color:
            return list.sorted {
                let c1 = $0.colorHex ?? ""
                let c2 = $1.colorHex ?? ""
                if c1 != c2 { return c1 < c2 }
                return $0.pageIndex < $1.pageIndex
            }
        }
    }

    private var totalNotesCount: Int {
        bookHighlights.filter { !($0.noteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: Overview & Filter Header
                headerStatsAndFiltersBar

                Divider()

                // MARK: Highlights Content List
                if bookHighlights.isEmpty {
                    emptyStateView
                } else if filteredHighlights.isEmpty {
                    noMatchesStateView
                } else {
                    highlightsListView
                }
            }
            .background(colorScheme == .dark ? Color(hex: "#121214") : Color(hex: "#F9F9FB"))
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .medium))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportHighlightsAsMarkdown()
                        } label: {
                            Label("Copy as Markdown", systemImage: "doc.on.doc")
                        }

                        Button {
                            let csv = HighlightExportService.shared.exportToReadwiseCSV(
                                bookTitle: bookTitle,
                                author: nil,
                                annotations: bookHighlights
                            )
                            UIPasteboard.general.string = csv
                            HapticEngine.selection()
                        } label: {
                            Label("Copy Readwise CSV", systemImage: "tablecells")
                        }

                        ShareLink(item: generateExportText()) {
                            Label("Share as Markdown", systemImage: "square.and.arrow.up")
                        }

                        ShareLink(item: HighlightExportService.shared.exportToReadwiseCSV(bookTitle: bookTitle, author: nil, annotations: bookHighlights)) {
                            Label("Share Readwise CSV", systemImage: "arrow.up.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .disabled(bookHighlights.isEmpty)
                }
            }
            .sheet(item: $activeHighlightToEdit) { annotation in
                AnnotationEditSheet(annotation: annotation)
            }
            .alert("Delete Highlight?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let highlight = highlightToDelete {
                        deleteHighlight(highlight)
                    }
                }
                Button("Cancel", role: .cancel) {
                    highlightToDelete = nil
                }
            } message: {
                Text("Are you sure you want to remove this highlight and its attached notes?")
            }
            .onAppear {
                loadHighlights()
            }
            .onChange(of: activeHighlightToEdit) { oldVal, newVal in
                if oldVal != nil && newVal == nil {
                    loadHighlights()
                }
            }
        }
    }

    // MARK: - Header Stats & Filters Bar
    private var headerStatsAndFiltersBar: some View {
        VStack(spacing: 10) {
            // Category & Sort Controls
            HStack(spacing: 8) {
                // Category Filter Pills
                HStack(spacing: 6) {
                    ForEach(AnnotationCategoryFilter.allCases) { cat in
                        Button {
                            HapticEngine.selection()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                categoryFilter = cat
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 10, weight: categoryFilter == cat ? .bold : .medium))
                                Text(cat.rawValue)
                                    .font(.system(size: 11, weight: categoryFilter == cat ? .bold : .medium, design: .rounded))
                            }
                            .foregroundColor(categoryFilter == cat ? .white : .primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(categoryFilter == cat ? Color.orange : Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Spacer()
                
                // Sort Segmented Picker
                Picker("Sort", selection: $sortOption) {
                    ForEach(AnnotationSortOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Search Field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextField("Search quotes, thoughts, tags...", text: $searchQuery)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            // Color Filter Chips
            let colors = availableColors
            if colors.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                selectedColorFilter = nil
                            }
                        } label: {
                            Text("All")
                                .font(.system(size: 11, weight: selectedColorFilter == nil ? .bold : .medium))
                                .foregroundStyle(selectedColorFilter == nil ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(selectedColorFilter == nil ? Theme.blue : Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(colors, id: \.self) { hex in
                            let count = bookHighlights.filter { ($0.colorHex ?? "").localizedCaseInsensitiveContains(hex) }.count
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    if selectedColorFilter == hex {
                                        selectedColorFilter = nil
                                    } else {
                                        selectedColorFilter = hex
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 10, height: 10)
                                    Text("\(count)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(selectedColorFilter == hex ? .white : .primary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(selectedColorFilter == hex ? Theme.blue : Color(hex: hex).opacity(0.18), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color(hex: hex).opacity(0.4), lineWidth: selectedColorFilter == hex ? 0 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
            }
        }
        .padding(.bottom, 6)
        .background(colorScheme == .dark ? Color(hex: "#1A1A1E") : Color.white)
    }

    // MARK: - Highlights List View
    private var highlightsListView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(filteredHighlights) { highlight in
                    highlightCard(highlight)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Executive Quote Card
    private func highlightCard(_ highlight: SDAnnotation) -> some View {
        let accentColor = Color(hex: highlight.colorHex ?? "#FFD60A")
        let isExpanded = expandedQuoteIDs.contains(highlight.id)
        let isCopied = copiedHighlightID == highlight.id

        return VStack(alignment: .leading, spacing: 10) {
            // Card Top Meta Row: Page badge + Chapter title + Accent dot
            HStack(spacing: 8) {
                // Jump to Page Button
                Button {
                    HapticEngine.selection()
                    onJumpToHighlight?(highlight)
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 11))
                        Text("Page \(highlight.pageIndex + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                if let chapter = highlight.chapterTitle, !chapter.isEmpty {
                    Text(chapter)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Highlight Color Indicator
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: accentColor.opacity(0.6), radius: 3)
            }

            // The Highlighted Quote (Executive Serif Styling)
            if let text = highlight.selectedText, !text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    // Vertical Glowing Accent Bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor)
                        .frame(width: 3.5)
                        .shadow(color: accentColor.opacity(0.4), radius: 2)

                    Text("“\(text)”")
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .lineLimit(isExpanded ? nil : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                if isExpanded {
                                    expandedQuoteIDs.remove(highlight.id)
                                } else {
                                    expandedQuoteIDs.insert(highlight.id)
                                }
                            }
                        }
                }
                .padding(.vertical, 2)
            }

            // User Note Callout Bubble
            if let note = highlight.noteText, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.blue)
                        .padding(.top, 2)

                    Text(note)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }

            // Tags Row
            if let tags = highlight.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.blue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Theme.blue.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }

            Divider()
                .padding(.top, 2)

            // Action Row
            HStack(spacing: 16) {
                // Copy Quote
                Button {
                    if let text = highlight.selectedText {
                        UIPasteboard.general.string = text
                        HapticEngine.selection()
                        withAnimation { copiedHighlightID = highlight.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedHighlightID == highlight.id {
                                copiedHighlightID = nil
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)

                // Share Quote
                if let text = highlight.selectedText {
                    let shareContent = "“\(text)”\n\n— \(bookTitle)"
                    ShareLink(item: shareContent) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11))
                            Text("Share")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Edit Note
                Button {
                    HapticEngine.selection()
                    activeHighlightToEdit = highlight
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                        Text("Note")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain)

                // Delete Button
                Button {
                    HapticEngine.light()
                    highlightToDelete = highlight
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(colorScheme == .dark ? Color(hex: "#1E1E22") : Color.white)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 6, x: 0, y: 3)
        )
    }

    // MARK: - Empty States
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "highlighter")
                .font(.system(size: 48))
                .foregroundStyle(Color.orange.opacity(0.8))
                .padding(20)
                .background(Color.orange.opacity(0.12), in: Circle())

            Text("No Highlights Yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Text("Select any passage of text in \"\(bookTitle)\" to create your first highlight, add personal thoughts, and organize with tags.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .lineSpacing(3)

            Spacer()
        }
        .padding(24)
    }

    private var noMatchesStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No Matching Highlights")
                .font(.headline)

            Text("Try clearing your search query or selecting \"All\" colors.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Clear Filters") {
                withAnimation {
                    searchQuery = ""
                    selectedColorFilter = nil
                    selectedTagFilter = nil
                }
            }
            .font(.subheadline.bold())
            .padding(.top, 4)

            Spacer()
        }
        .padding()
    }

    // MARK: - Data Management & Export
    private func loadHighlights() {
        let hDescriptor = FetchDescriptor<SDAnnotation>(
            predicate: #Predicate {
                ($0.kindRaw == "highlight" || $0.kindRaw == "underline" || $0.kindRaw == "strikeOut") &&
                $0.pdfID == targetPDFID
            }
        )
        if let h = try? modelContext.fetch(hDescriptor) {
            self.bookHighlights = h
        }

        // Auto-sync fallback from AnnotationStore if needed
        let storeAnns = AnnotationStore.shared.annotations(for: targetPDFID)
            .filter { $0.kind == .highlight || $0.kind == .underline || $0.kind == .strikeOut }
        if !storeAnns.isEmpty {
            var didImport = false
            for ann in storeAnns {
                let annID = ann.id
                let checkDesc = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.id == annID })
                if (try? modelContext.fetch(checkDesc).first) == nil {
                    let sd = SDAnnotation(from: ann)
                    modelContext.insert(sd)
                    didImport = true
                }
            }
            if didImport {
                try? modelContext.save()
                if let refreshed = try? modelContext.fetch(hDescriptor) {
                    self.bookHighlights = refreshed
                }
            }
        }
    }

    private func deleteHighlight(_ annotation: SDAnnotation) {
        let id = annotation.id
        modelContext.delete(annotation)
        try? modelContext.save()
        AnnotationStore.shared.delete(id: id, pdfID: targetPDFID)
        withAnimation {
            bookHighlights.removeAll { $0.id == id }
        }
        highlightToDelete = nil
        HapticEngine.medium()
    }

    private func generateExportText() -> String {
        var md = "# Highlights from \(bookTitle)\n\n"
        md += "*Exported from InksyncPro on \(Date().formatted(date: .abbreviated, time: .shortened))*\n\n---\n\n"

        for h in filteredHighlights {
            if let text = h.selectedText {
                md += "> \"\(text)\"\n"
                md += "— Page \(h.pageIndex + 1)"
                if let chap = h.chapterTitle, !chap.isEmpty {
                    md += " (\(chap))"
                }
                md += "\n"

                if let note = h.noteText, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    md += "\n**Note**: \(note)\n"
                }

                if let tags = h.tags, !tags.isEmpty {
                    md += "\n**Tags**: " + tags.map { "#\($0)" }.joined(separator: " ") + "\n"
                }

                md += "\n---\n\n"
            }
        }
        return md
    }

    private func exportHighlightsAsMarkdown() {
        let md = generateExportText()
        UIPasteboard.general.string = md
        HapticEngine.selection()
    }
}
