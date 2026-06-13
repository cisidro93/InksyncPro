import SwiftUI

extension Binding where Value == String? {
    var bound: Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? "" },
            set: { self.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

struct MetadataEditorSheet: View {
    @Binding var pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @Environment(\.dismiss) var dismiss
    
    // Local State for editing (so we can cancel)
    @State private var editedMetadata: PDFMetadata
    
    // Auto-Fill State
    @State private var isSearching = false
    @State private var searchResults: [ComicVineVolume] = []
    @State private var showResults = false
    
    // BookVine State
    @State private var bookSearchResults: [GoogleBookItem] = []
    @State private var showBookResults = false
    
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
        NavigationStack {
            Form {
                autoFillSection()
                coreInfoSection()
                creditsSection()
                
                Section(header: Text("Tags")) {
                    TagEditorView(tags: $editedMetadata.tags)
                }
                
                Section(header: Text("Summary")) {
                    TextEditor(text: $editedMetadata.summary.bound)
                        .frame(height: 100)
                }
                
                systemSection()
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
            // ComicVine Results Sheet
            .sheet(isPresented: $showResults) {
                SearchResultsView(results: searchResults, onSelect: fetchDetails)
            }
            // BookVine Results Sheet
            .sheet(isPresented: $showBookResults) {
                BookVineResultsView(results: bookSearchResults, onSelect: applyBookMetadata)
            }
            .alert("Rename File?", isPresented: Binding(
                get: { showingRenamePrompt },
                set: { showingRenamePrompt = $0 }
            )) {
                Button("Rename on Disk", role: .destructive) {
                    Task { await physicalRenameFile() }
                }
                Button("Keep Original Name", role: .cancel) { saveChanges() }
            } message: {
                Text("Would you like to permanently rename the underlying file on your iPad to:\n\n'\(newSuggestedCacheName)'?")
            }
        }
    }
    
    // MARK: - View Builders
    
    @ViewBuilder
    private func autoFillSection() -> some View {
        Section(header: Text("Auto-Fill")) {
            if settingsManager.conversionSettings.comicVineAPIKey.isEmpty {
                Text("⚠️ Add a ComicVine API Key in Settings → Integrations to enable Auto-Fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                HStack(spacing: 16) {
                    if !settingsManager.conversionSettings.comicVineAPIKey.isEmpty && pdf.contentType != .book {
                        Button(action: searchComicVine) {
                            Label("Fetch ComicVine", systemImage: "network")
                        }.disabled(isSearching)
                    }
                    if pdf.contentType == .book || pdf.url.pathExtension.lowercased() == "epub" {
                        Button(action: searchBookVine) {
                            Label("Fetch BookVine", systemImage: "book.pages")
                        }.disabled(isSearching)
                    }
                    if pdf.contentType != .book {
                        Button(action: { runLocalXMLExtract() }) {
                            if isSearching { ProgressView() } else { Label("Auto-Fetch XML", systemImage: "doc.text.viewfinder") }
                        }
                    }
                }
                if isSearching { ProgressView().padding(.top, 4) }
            }
            if let error = errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }
    
    @ViewBuilder
    private func coreInfoSection() -> some View {
        Section(header: Text("Core Info")) {
            TextField("Title", text: $editedMetadata.title)
            TextField("Series", text: $editedMetadata.series.bound)
            TextField("Volume", text: $editedMetadata.volume.bound)
            TextField("Issue #", text: $editedMetadata.issueNumber.bound)
        }
    }
    
    @ViewBuilder
    private func creditsSection() -> some View {
        Section(header: Text("Credits")) {
            TextField("Writer", text: $editedMetadata.writer.bound)
            TextField("Penciller", text: $editedMetadata.penciller.bound)
            TextField("Publisher", text: $editedMetadata.publisher.bound)
            TextField("Publication Date (YYYY-MM-DD)", text: Binding(
                get: {
                    if let date = editedMetadata.publicationDate { return dateFormatter.string(from: date) }
                    return ""
                },
                set: { newValue in
                    if let date = dateFormatter.date(from: newValue) { editedMetadata.publicationDate = date }
                    else if newValue.isEmpty { editedMetadata.publicationDate = nil }
                }
            ))
        }
    }
    
    @ViewBuilder
    private func systemSection() -> some View {
        Section(header: Text("System")) {
            if let id = editedMetadata.universalIssueID {
                HStack { Text("ComicVine ID"); Spacer(); Text("\(id)").foregroundColor(.secondary) }
            }
            Picker("Content Type", selection: $pdf.contentType) {
                ForEach(ContentType.allCases, id: \.self) { type in
                    Label(type.rawValue, systemImage: type.icon).tag(type)
                }
            }
            Toggle("Private File", isOn: $pdf.isPrivate)
        }
    }
    
    // MARK: - State & Logic
    
    @State private var showingRenamePrompt = false
    @State private var newSuggestedCacheName = ""
    
    func runLocalXMLExtract() {
        isSearching = true
        errorMessage = nil
        
        Task {
            let parsedInfo = ComicInfoParser.parse(from: pdf.url)
            let renameString = try? LocalComicInfoService.shared.generateDeterministicFilename(from: pdf.url)
            
            await MainActor.run {
                if let info = parsedInfo {
                    if let series = info.series { editedMetadata.series = series; editedMetadata.volume = series }
                    if let title = info.title { editedMetadata.title = title }
                    if let number = info.number { editedMetadata.issueNumber = number }
                    if let writer = info.writer { editedMetadata.writer = writer }
                    if let publisher = info.publisher { editedMetadata.publisher = publisher }
                    if let summary = info.summary { editedMetadata.summary = summary }
                    if let year = info.year {
                        var comps = DateComponents()
                        comps.year = year
                        comps.month = 1
                        comps.day = 1
                        editedMetadata.publicationDate = Calendar.current.date(from: comps)
                    }
                    
                    for tag in info.tags {
                        if !editedMetadata.tags.contains(tag) { editedMetadata.tags.append(tag) }
                    }
                    if !editedMetadata.tags.contains("Local XML Scanned") {
                        editedMetadata.tags.append("Local XML Scanned")
                    }
                } else {
                    errorMessage = "XML Extraction Failed: No valid ComicInfo.xml found."
                }
                
                isSearching = false
                
                if let suggested = renameString {
                    newSuggestedCacheName = suggested
                    showingRenamePrompt = true
                } else if parsedInfo != nil {
                    saveChanges()
                }
            }
        }
    }
    
    func physicalRenameFile() async {
        do {
            try await conversionManager.safelyRenamePhysicalFile(pdf: pdf, newName: newSuggestedCacheName)
            await MainActor.run {
                saveChanges() // Save and dismiss
            }
        } catch {
            await MainActor.run {
                errorMessage = "Rename Failed: \(error.localizedDescription)"
            }
        }
    }
    
    func saveChanges() {
        pdf.metadata = editedMetadata
        conversionManager.updateMetadata(for: pdf, with: editedMetadata, newCover: nil)
        dismiss()
    }
    
    func searchComicVine() {
        guard !settingsManager.conversionSettings.comicVineAPIKey.isEmpty else { return }
        
        isSearching = true
        errorMessage = nil
        
        let query = MetadataHeuristics.cleanFilename(pdf.name)
        
        Task {
            do {
                let key = settingsManager.conversionSettings.comicVineAPIKey
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
    
    func searchBookVine() {
        isSearching = true
        errorMessage = nil
        
        let query = MetadataHeuristics.cleanFilename(pdf.name)
        
        Task {
            do {
                let results = try await BookMetadataService.shared.searchBooks(query: query)
                
                await MainActor.run {
                    self.bookSearchResults = results
                    self.isSearching = false
                    if results.isEmpty {
                        self.errorMessage = "No BookVine results found for '\(query)'"
                    } else {
                        self.showBookResults = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSearching = false
                    self.errorMessage = "Google Books API Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func fetchAndApplyOnlineCover(urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        
        let result = await Task.detached(priority: .userInitiated) { () -> (URL, UUID)? in
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data),
                  let jpegData = image.jpegData(compressionQuality: 0.9) else { return nil }
            
            guard image.size.width > 20 && image.size.height > 20 else { return nil }
            
            let variantID = UUID()
            let coversDir = await ConversionManager.getCoversDirectory()
            let variantURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
            do {
                try jpegData.write(to: variantURL)
                return (variantURL, variantID)
            } catch {
                return nil
            }
        }.value
        
        if let (variantURL, variantID) = result {
            await MainActor.run {
                pdf.metadata.coverVariants[variantID] = variantURL
                pdf.metadata.selectedCoverID = variantID
                editedMetadata.coverVariants[variantID] = variantURL
                editedMetadata.selectedCoverID = variantID
            }
        }
    }
    
    func applyBookMetadata(_ book: GoogleBookItem) {
        showBookResults = false
        
        let info = book.volumeInfo
        
        editedMetadata.title = info.title
        editedMetadata.series = info.subtitle
        editedMetadata.publisher = info.publisher
        
        if let authors = info.authors, !authors.isEmpty {
            editedMetadata.writer = authors.joined(separator: ", ")
        }
        
        if let desc = info.description {
            editedMetadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
        }
        
        if let dateString = info.publishedDate {
            // Google Books dates can be "YYYY-MM-DD", "YYYY-MM", or just "YYYY"
            let formatter = DateFormatter()
            if dateString.count == 4 {
                formatter.dateFormat = "yyyy"
            } else if dateString.count == 7 {
                formatter.dateFormat = "yyyy-MM"
            } else {
                formatter.dateFormat = "yyyy-MM-dd"
            }
            editedMetadata.publicationDate = formatter.date(from: dateString)
        }
        
        editedMetadata.tags.append("Google Books")
        
        if let imageURLStr = info.imageLinks?.bestQualityURL ?? info.imageLinks?.thumbnail, let url = URL(string: imageURLStr.replacingOccurrences(of: "http://", with: "https://")) {
            Task {
                await fetchAndApplyOnlineCover(urlString: url.absoluteString)
                await MainActor.run { saveChanges() }
            }
        } else {
            saveChanges()
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
                     editedMetadata.universalSeriesID = "\(volume.id)"
                     editedMetadata.volume = volume.name
                     editedMetadata.publisher = volume.publisher?.name
                     isSearching = false
                     errorMessage = "Could not detect issue number from filename. Applied series info only."
                     saveChanges()
                 }
             }
            return
        }
        
        Task {
            do {
                let key = settingsManager.conversionSettings.comicVineAPIKey
                if let issue = try await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: "\(issueNum)", apiKey: key) {
                    
                    await MainActor.run {
                        // Populate Fields
                        editedMetadata.series = volume.name
                        editedMetadata.universalSeriesID = "\(volume.id)"
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
                        
                        editedMetadata.universalIssueID = "\(issue.id)"
                        isSearching = false
                    }
                    
                    if let imageURLStr = issue.image?.original_url ?? issue.image?.medium_url {
                        Task {
                            await fetchAndApplyOnlineCover(urlString: imageURLStr)
                            await MainActor.run { saveChanges() }
                        }
                    } else {
                        await MainActor.run { saveChanges() }
                    }
                } else {
                     await MainActor.run {
                         // Fallback to basic info
                         editedMetadata.series = volume.name
                         editedMetadata.universalSeriesID = "\(volume.id)"
                         editedMetadata.volume = volume.name
                         editedMetadata.issueNumber = "\(issueNum)"
                         editedMetadata.publisher = volume.publisher?.name
                         isSearching = false
                         errorMessage = "Issue #\(issueNum) not found in volume. Applied series info."
                         saveChanges()
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
        NavigationStack {
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

// Subview for Google Books Results
struct BookVineResultsView: View {
    let results: [GoogleBookItem]
    let onSelect: (GoogleBookItem) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List(results) { book in
                Button {
                    onSelect(book)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        if let urlStr = book.volumeInfo.imageLinks?.smallThumbnail ?? book.volumeInfo.imageLinks?.thumbnail,
                           let url = URL(string: urlStr.replacingOccurrences(of: "http://", with: "https://")) {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                Color.gray.opacity(0.3)
                            }
                            .frame(width: 40, height: 60)
                            .cornerRadius(4)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 40, height: 60)
                                .overlay(Image(systemName: "book.closed").foregroundColor(.secondary))
                                .cornerRadius(4)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.volumeInfo.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            if let authors = book.volumeInfo.authors {
                                Text(authors.joined(separator: ", "))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack {
                                if let pub = book.volumeInfo.publisher {
                                    Text(pub)
                                }
                                Spacer()
                                if let date = book.volumeInfo.publishedDate {
                                    Text(date)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Select Book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
