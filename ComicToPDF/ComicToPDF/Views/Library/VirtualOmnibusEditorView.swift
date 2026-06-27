import SwiftUI

struct VirtualOmnibusEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    /// The virtual omnibus being edited (nil if creating a new one)
    let omnibus: VirtualOmnibus?
    
    @State private var name: String = ""
    @State private var fileIDs: [UUID] = []
    @State private var remoteSyncURL: String = ""
    
    // Search & Suggestion State
    @State private var searchQuery: String = ""
    @State private var suggestions: [ConvertedPDF] = []
    
    init(omnibus: VirtualOmnibus? = nil, initialFileIDs: [UUID] = [], suggestedName: String = "") {
        self.omnibus = omnibus
        let nameVal = omnibus?.name ?? suggestedName
        _name = State(initialValue: nameVal)
        _remoteSyncURL = State(initialValue: omnibus?.remoteSyncURL ?? "")
        
        let fileIDsVal = omnibus?.fileIDs ?? initialFileIDs
        _fileIDs = State(initialValue: fileIDsVal)
    }
    
    var selectedFiles: [ConvertedPDF] {
        fileIDs.compactMap { id in
            conversionManager.convertedPDFs.first(where: { $0.id == id })
        }
    }
    
    var searchResults: [ConvertedPDF] {
        if searchQuery.isEmpty {
            return []
        }
        return conversionManager.convertedPDFs.filter { pdf in
            pdf.name.localizedCaseInsensitiveContains(searchQuery) && !fileIDs.contains(pdf.id)
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()
                
                VStack(spacing: InkSpacing.sectionGap) {
                    // Header Form
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Volume Name")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.inkTextSecondary)
                            
                            TextField("e.g. Spider-Man: Blue", text: $name)
                                .font(.system(.body, design: .rounded))
                                .padding()
                                .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous)
                                        .strokeBorder(Color.inkBorderSubtle, lineWidth: 1)
                                )
                                .foregroundColor(.inkTextPrimary)
                                .onChange(of: name) { _, _ in
                                    updateSuggestions()
                                }
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Remote Sync URL (CBL or CSV)")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.inkTextSecondary)
                            
                            TextField("e.g. https://example.com/readinglist.cbl", text: $remoteSyncURL)
                                .font(.system(.body, design: .rounded))
                                .padding()
                                .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous)
                                        .strokeBorder(Color.inkBorderSubtle, lineWidth: 1)
                                )
                                .foregroundColor(.inkTextPrimary)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                            
                            Text("Link this volume to a remote ComicRack reading list (.cbl) or standard CSV sheet hosted online (e.g. GitHub, Dropbox). The app will automatically background-sync the list order and align your local files.")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.inkTextSecondary)
                                .lineSpacing(3.5)
                                .padding(.horizontal, 4)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // Main Editing Area split by tab/selection
                    List {
                        if !suggestions.isEmpty {
                            Section {
                                ForEach(suggestions) { pdf in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(pdf.name)
                                                .font(.system(.body, design: .rounded))
                                                .foregroundColor(.inkTextPrimary)
                                            Text(pdf.formattedSize)
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundColor(.inkTextSecondary)
                                        }
                                        Spacer()
                                        Button {
                                            withAnimation {
                                                fileIDs.append(pdf.id)
                                                updateSuggestions()
                                            }
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.title3)
                                                .foregroundColor(.inkGreen)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 4)
                                }
                            } header: {
                                HStack {
                                    Text("Smart Suggestions")
                                    Spacer()
                                    Button("Add All") {
                                        withAnimation {
                                            for pdf in suggestions {
                                                fileIDs.append(pdf.id)
                                            }
                                            suggestions.removeAll()
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.inkBlue)
                                }
                            }
                        }
                        
                        Section {
                            if selectedFiles.isEmpty {
                                Text("No issues added yet. Use the search bar or suggestions below to build your virtual omnibus volume.")
                                    .font(.system(.body, design: .rounded))
                                    .foregroundColor(.inkTextSecondary)
                                    .padding(.vertical)
                                    .listRowBackground(Color.inkSurface)
                            } else {
                                ForEach(selectedFiles) { pdf in
                                    HStack(spacing: 12) {
                                        Image(systemName: "line.3.horizontal")
                                            .foregroundColor(.inkTextTertiary)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(pdf.name)
                                                .font(.system(.body, design: .rounded))
                                                .foregroundColor(.inkTextPrimary)
                                                .lineLimit(1)
                                            Text(pdf.metadata.issueNumber.map { "Issue #\($0)" } ?? "No Issue Number")
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundColor(.inkTextSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .listRowBackground(Color.inkSurface)
                                }
                                .onMove { indices, newOffset in
                                    fileIDs.move(fromOffsets: indices, toOffset: newOffset)
                                }
                                .onDelete { indices in
                                    fileIDs.remove(atOffsets: indices)
                                    updateSuggestions()
                                }
                            }
                        } header: {
                            Text("Included Issues (Drag to Reorder)")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    
                    // Search Drawer at the bottom
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.inkTextSecondary)
                            TextField("Search Library to Add Issues...", text: $searchQuery)
                                .font(.system(.body, design: .rounded))
                                .foregroundColor(.inkTextPrimary)
                            if !searchQuery.isEmpty {
                                Button {
                                    searchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.inkTextTertiary)
                                }
                            }
                        }
                        .padding()
                        .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous)
                                .strokeBorder(Color.inkBorderSubtle, lineWidth: 1)
                        )
                        .padding(.horizontal)
                        
                        if !searchResults.isEmpty {
                            ScrollView {
                                LazyVStack(spacing: 1) {
                                    ForEach(searchResults) { pdf in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(pdf.name)
                                                    .font(.system(.body, design: .rounded))
                                                    .foregroundColor(.inkTextPrimary)
                                                Text(pdf.metadata.series ?? "No Series")
                                                    .font(.system(.caption, design: .rounded))
                                                    .foregroundColor(.inkTextSecondary)
                                            }
                                            Spacer()
                                            Button {
                                                withAnimation {
                                                    fileIDs.append(pdf.id)
                                                    searchQuery = ""
                                                    updateSuggestions()
                                                }
                                            } label: {
                                                Image(systemName: "plus.circle.fill")
                                                    .foregroundColor(.inkBlue)
                                                    .font(.title3)
                                            }
                                        }
                                        .padding()
                                        .background(Color.inkSurfaceRaised)
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                            .cornerRadius(InkRadius.thumbnail)
                            .padding(.horizontal)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle(omnibus == nil ? "Create Virtual Omnibus" : "Edit Virtual Omnibus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.inkTextSecondary)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundColor(name.isEmpty ? .inkTextTertiary : .inkBlue)
                }
            }
            .onAppear {
                updateSuggestions()
            }
        }
    }
    
    private func updateSuggestions() {
        guard !name.isEmpty else {
            suggestions = []
            return
        }
        
        let allPDFs = conversionManager.convertedPDFs
        suggestions = allPDFs.filter { pdf in
            // Must not be already in the omnibus
            guard !fileIDs.contains(pdf.id) else { return false }
            
            // Check Levenshtein similarity against target title
            let score = SeriesHeuristicsMatcher.shared.levenshteinSimilarity(between: pdf.metadata.series ?? pdf.name, and: name)
            return score >= 0.75
        }
        // Limit to top 5 suggestions to keep screen clean
        suggestions = Array(suggestions.prefix(5))
    }
    
    private func save() {
        let activeId = omnibus?.id ?? UUID()
        let cleanSyncURL = remoteSyncURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = VirtualOmnibus(
            id: activeId,
            name: name,
            fileIDs: fileIDs,
            coverFileID: omnibus?.coverFileID,
            lastReadPageIndex: omnibus?.lastReadPageIndex ?? 0,
            lastReadFileID: omnibus?.lastReadFileID,
            addedAt: omnibus?.addedAt ?? Date(),
            modifiedAt: Date(),
            remoteSyncURL: cleanSyncURL.isEmpty ? nil : cleanSyncURL,
            lastSyncedAt: omnibus?.lastSyncedAt
        )
        
        var list = conversionManager.virtualOmnibuses
        if let idx = list.firstIndex(where: { $0.id == activeId }) {
            list[idx] = record
        } else {
            list.append(record)
        }
        
        conversionManager.virtualOmnibuses = list
        
        // Trigger a sync if URL is set and changed
        if let url = record.remoteSyncURL, !url.isEmpty, url != omnibus?.remoteSyncURL {
            Task {
                await LibraryService.shared.syncRemoteVirtualOmnibus(record)
            }
        }
        
        dismiss()
    }
}
