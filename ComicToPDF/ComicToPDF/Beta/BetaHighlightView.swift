import SwiftUI
import SwiftData

struct BetaHighlightView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BetaHighlight.dateCreated, order: .reverse) private var allHighlights: [BetaHighlight]
    
    @State private var searchText = ""
    @State private var selectedHighlightForEdit: BetaHighlight? = nil
    @State private var editedNote = ""
    
    // Export State
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                searchBar
                
                if filteredHighlights.isEmpty {
                    emptyStateView
                } else {
                    highlightsList
                }
            }
            .navigationTitle("Highlights")
            .toolbar {
                if !allHighlights.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            exportHighlights()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
            }
            .sheet(item: $selectedHighlightForEdit) { highlight in
                editNoteSheet(highlight: highlight)
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = shareURL {
                    BetaShareSheet(activityItems: [url])
                }
            }
        }
    }
    
    // MARK: - Search Bar
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.gray)
            TextField("Search quotes or notes...", text: $searchText)
                .foregroundStyle(.white)
                .tint(.orange)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .padding()
        .background(Color.black.opacity(0.2))
    }
    
    private var groupedHighlights: [String: [BetaHighlight]] {
        Dictionary(grouping: filteredHighlights, by: { $0.book?.title ?? "Unknown Book" })
    }
    
    private var highlightsList: some View {
        let groups = groupedHighlights
        return List {
            ForEach(groups.keys.sorted(), id: \.self) { title in
                Section(header: Text(title).font(.subheadline.bold()).foregroundStyle(Color.orange)) {
                    ForEach(groups[title] ?? []) { highlight in
                        highlightRow(highlight: highlight)
                            .listRowBackground(Color(hex: "#1E1E24").opacity(0.6))
                            .listRowSeparatorTint(Color.white.opacity(0.1))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteHighlight(highlight)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func highlightRow(highlight: BetaHighlight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PAGE \(highlight.pageIndex + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundStyle(Color.orange)
                    .cornerRadius(4)
                
                Spacer()
                
                Text(highlight.dateCreated, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            
            // Highlighted Quote Text
            Text("\"\(highlight.text)\"")
                .font(.system(size: 14, weight: .medium))
                .italic()
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .overlay(
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 3)
                        .padding(.vertical, 2),
                    alignment: .leading
                )
            
            // Personal Note
            if !highlight.note.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note:")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.gray)
                    Text(highlight.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .cornerRadius(6)
            }
            
            // Edit Note Trigger
            Button {
                editedNote = highlight.note
                selectedHighlightForEdit = highlight
            } label: {
                Label(highlight.note.isEmpty ? "Add Note" : "Edit Note", systemImage: "pencil.line")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
    
    // MARK: - Edit Note Sheet
    
    private func editNoteSheet(highlight: BetaHighlight) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("\"\(highlight.text)\"")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.gray)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                
                TextEditor(text: $editedNote)
                    .padding(5)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .foregroundStyle(.white)
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                
                Spacer()
            }
            .padding()
            .navigationTitle("Annotation Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selectedHighlightForEdit = nil
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        highlight.note = editedNote
                        try? modelContext.save()
                        selectedHighlightForEdit = nil
                    }
                    .bold()
                    .foregroundStyle(Color.orange)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "highlighter")
                .font(.system(size: 60))
                .foregroundStyle(.gray)
            
            Text("No Highlights Yet")
                .font(.headline)
                .foregroundStyle(.white)
            
            Text("While reading, open the toolbar menu and tap the highlighter to clip text and save reference quotes.")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
        }
    }
    
    // MARK: - Operations
    
    private var filteredHighlights: [BetaHighlight] {
        allHighlights.filter { hl in
            searchText.isEmpty ||
                hl.text.localizedCaseInsensitiveContains(searchText) ||
                hl.note.localizedCaseInsensitiveContains(searchText) ||
                (hl.book?.title.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    private func deleteHighlight(_ highlight: BetaHighlight) {
        modelContext.delete(highlight)
        try? modelContext.save()
    }
    
    private func exportHighlights() {
        let sorted = allHighlights.sorted { ($0.book?.title ?? "") < ($1.book?.title ?? "") }
        var mdText = "# Inksync Library Clippings & Highlights\n\n"
        
        let grouped = Dictionary(grouping: sorted, by: { $0.book?.title ?? "Unknown Book" })
        for title in grouped.keys.sorted() {
            mdText += "## \(title)\n\n"
            for hl in grouped[title] ?? [] {
                mdText += "- **Page \(hl.pageIndex + 1)**: *\"\(hl.text)\"*\n"
                if !hl.note.isEmpty {
                    mdText += "  Note: \(hl.note)\n"
                }
                mdText += "\n"
            }
            mdText += "---\n\n"
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Inksync_Highlights.md")
        try? mdText.write(to: tempURL, atomically: true, encoding: .utf8)
        
        self.shareURL = tempURL
        self.showingShareSheet = true
    }
}
