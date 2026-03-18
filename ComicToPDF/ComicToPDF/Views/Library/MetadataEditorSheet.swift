import SwiftUI

struct MetadataEditorSheet: View {
    @Binding var pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    // Local State for editing (so we can cancel)
    @State private var editedMetadata: PDFMetadata
    
    // Auto-Fill State
    @State private var isSearching = false
    @State private var searchResults: [ComicVineVolume] = []
    @State private var showResults = false
    @State private var errorMessage: String?
    
    // Date Formatter
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    
    init(pdf: Binding<ConvertedPDF>) {
        self._pdf = pdf
        self._editedMetadata = State(initialValue: pdf.wrappedValue.metadata)
    }
    
    var body: some View {
        NavigationView {
            Form {
                // MARK: - Auto-Fill Section
                Section(header: Text("Auto-Fill")) {
                    if conversionManager.conversionSettings.comicVineAPIKey.isEmpty {
                        Text("⚠️ Add API Key in Settings to enable Auto-Fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Button(action: searchComicVine) {
                            HStack {
                                Label("Fetch from ComicVine", systemImage: "network")
                                if isSearching {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isSearching)
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                // MARK: - Core Metadata
                Section(header: Text("Core Info")) {
                    TextField("Title", text: $editedMetadata.title)
                    TextField("Series", text: Binding(get: { editedMetadata.series ?? "" }, set: { editedMetadata.series = $0.isEmpty ? nil : $0 }))
                    TextField("Volume", text: Binding(get: { editedMetadata.volume ?? "" }, set: { editedMetadata.volume = $0.isEmpty ? nil : $0 }))
                    TextField("Issue #", text: Binding(get: { editedMetadata.issueNumber ?? "" }, set: { editedMetadata.issueNumber = $0.isEmpty ? nil : $0 }))
                }
                
                // MARK: - Credits
                Section(header: Text("Credits")) {
                    TextField("Writer", text: Binding(get: { editedMetadata.writer ?? "" }, set: { editedMetadata.writer = $0.isEmpty ? nil : $0 }))
                    TextField("Penciller", text: Binding(get: { editedMetadata.penciller ?? "" }, set: { editedMetadata.penciller = $0.isEmpty ? nil : $0 }))
                    TextField("Publisher", text: Binding(get: { editedMetadata.publisher ?? "" }, set: { editedMetadata.publisher = $0.isEmpty ? nil : $0 }))
                    
                    // Date Binding
                    TextField("Publication Date (YYYY-MM-DD)", text: Binding(
                        get: {
                            if let date = editedMetadata.publicationDate {
                                return dateFormatter.string(from: date)
                            }
                            return ""
                        },
                        set: { newValue in
                            if let date = dateFormatter.date(from: newValue) {
                                editedMetadata.publicationDate = date
                            } else if newValue.isEmpty {
                                editedMetadata.publicationDate = nil
                            }
                        }
                    ))
                }
                
                // MARK: - Tags
                Section(header: Text("Tags")) {
                    TagEditorView(tags: $editedMetadata.tags)
                }
                
                // MARK: - Summary
                Section(header: Text("Summary")) {
                    TextEditor(text: Binding(get: { editedMetadata.summary ?? "" }, set: { editedMetadata.summary = $0.isEmpty ? nil : $0 }))
                        .frame(height: 100)
                }
                
                // MARK: - Technical
                Section(header: Text("System")) {
                    if let id = editedMetadata.comicVineID {
                        HStack {
                            Text("ComicVine ID")
                            Spacer()
                            Text("\(id)")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Picker("Content Type", selection: $pdf.contentType) {
                        ForEach(ContentType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    
                    Toggle("Private File", isOn: $pdf.isPrivate)
                }
            }
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                }
            }
            // Results Sheet
            .sheet(isPresented: $showResults) {
                SearchResultsView(results: searchResults, onSelect: fetchDetails)
            }
        }
    }
    
    // MARK: - Logic
    
    func saveChanges() {
        // We need to write back metadata
        pdf.metadata = editedMetadata
        
        // Trigger save in manager (assuming changes to @Published propagate, but we might need explicit save)
        conversionManager.saveLibrary()
        
        dismiss()
    }
    
    func searchComicVine() {
        guard !conversionManager.conversionSettings.comicVineAPIKey.isEmpty else { return }
        
        isSearching = true
        errorMessage = nil
        
        // Use filename or title
        // Heuristic: Try to extract Series Name from filename if Title is generic
        let query = MetadataHeuristics.cleanFilename(pdf.name)
        
        Task {
            do {
                let key = conversionManager.conversionSettings.comicVineAPIKey
                let results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: key)
                
                await MainActor.run {
                    self.searchResults = results
                    self.isSearching = false
                    if results.isEmpty {
                        self.errorMessage = "No results found for '\(query)'"
                    } else {
                        self.showResults = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSearching = false
                    self.errorMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func fetchDetails(for volume: ComicVineVolume) {
        showResults = false
        isSearching = true
        
        // Now fetch specific issue
        // We need to guess the issue number from the filename
        guard let issueNumStr = MetadataHeuristics.extractIssueNumber(from: pdf.name), let issueNum = Int(issueNumStr) else {
            // Apply partial volume data if issue number logic fails
             Task {
                 await MainActor.run {
                     editedMetadata.series = volume.name
                     editedMetadata.seriesID = volume.id
                     editedMetadata.volume = volume.name
                     editedMetadata.publisher = volume.publisher?.name
                     isSearching = false
                     errorMessage = "Could not detect issue number from filename. Applied series info only."
                 }
             }
            return
        }
        
        Task {
            do {
                let key = conversionManager.conversionSettings.comicVineAPIKey
                if let issue = try await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: "\(issueNum)", apiKey: key) {
                    
                    await MainActor.run {
                        // Populate Fields
                        editedMetadata.series = volume.name
                        editedMetadata.seriesID = volume.id
                        editedMetadata.volume = volume.name // Often Volume maps to Series Name in comics
                        editedMetadata.issueNumber = "\(issueNum)"
                        editedMetadata.publisher = volume.publisher?.name
                        
                        // Detail Fields
                        if let dateString = issue.cover_date {
                            editedMetadata.publicationDate = dateFormatter.date(from: dateString)
                        }
                        
                        // Parse HTML description to plain text (simple strip)
                        if let desc = issue.description {
                            editedMetadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                        }
                        
                        if let credits = issue.person_credits {
                            let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }
                            let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }
                            
                            editedMetadata.writer = writers.joined(separator: ", ")
                            editedMetadata.penciller = pencillers.joined(separator: ", ")
                        }
                        
                        editedMetadata.comicVineID = issue.id
                        isSearching = false
                    }
                } else {
                     await MainActor.run {
                         // Fallback to basic info
                         editedMetadata.series = volume.name
                         editedMetadata.seriesID = volume.id
                         editedMetadata.volume = volume.name
                         editedMetadata.issueNumber = "\(issueNum)"
                         editedMetadata.publisher = volume.publisher?.name
                         isSearching = false
                         errorMessage = "Issue #\(issueNum) not found in volume. Applied series info."
                     }
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    errorMessage = "Error fetching details: \(error.localizedDescription)"
                }
            }
        }
    }
    
}

// Subview for Results
struct SearchResultsView: View {
    let results: [ComicVineVolume]
    let onSelect: (ComicVineVolume) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List(results) { volume in
                Button {
                    onSelect(volume)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(volume.name).font(.headline)
                        HStack {
                            Text(volume.publisher?.name ?? "Unknown Publisher")
                            Spacer()
                            if let year = volume.start_year {
                                Text(year)
                            }
                            Text("(\(volume.count_of_issues ?? 0) issues)")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Select Series")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
