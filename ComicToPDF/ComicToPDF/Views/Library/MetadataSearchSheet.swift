import SwiftUI

struct MetadataSearchSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let pdf: ConvertedPDF
    // Service is now a singleton
    
    @State private var query = ""
    @State private var comicResults: [ComicVineVolume] = []
    @State private var bookResults: [GoogleBookItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false
    
    // Auto-Select the platform based on File Type
    private var isBookMode: Bool {
        return pdf.contentType == .book || pdf.fileURL.pathExtension.lowercased() == "epub"
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // Search Bar
                HStack {
                    TextField("Series Name (e.g. Saga)", text: $query)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit { performSearch() }
                    
                    Button(action: performSearch) {
                        Image(systemName: "magnifyingglass")
                            .padding(8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding()
                
                // API Key Warning (Only pertinent to ComicVine)
                if !isBookMode && conversionManager.conversionSettings.comicVineAPIKey.isEmpty {
                    Text("⚠️ Please set ComicVine API Key in Settings")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.bottom)
                }
                
                // Results List
                if isLoading {
                    ProgressView()
                    Spacer()
                } else if isBookMode {
                    List(bookResults) { book in
                        Button(action: { selectBook(book) }) {
                            HStack {
                                if let urlStr = book.volumeInfo.imageLinks?.bestQualityURL,
                                   let url = URL(string: urlStr) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            Color.gray.frame(width: 55, height: 75)
                                        }
                                    }
                                    .frame(width: 50, height: 75)
                                    .cornerRadius(4)
                                } else {
                                    Rectangle().fill(Color.gray).frame(width: 50, height: 75)
                                        .overlay(Image(systemName: "book.closed").foregroundColor(.white))
                                }
                                
                                VStack(alignment: .leading) {
                                    Text(book.volumeInfo.title).font(.headline)
                                    if let authors = book.volumeInfo.authors {
                                        Text(authors.joined(separator: ", ")).font(.caption).foregroundColor(.secondary)
                                    }
                                    if let publisher = book.volumeInfo.publisher {
                                        Text(publisher).font(.caption2).foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    List(comicResults) { volume in
                        Button(action: { selectVolume(volume) }) {
                            HStack {
                                AsyncImage(url: URL(string: volume.image?.icon_url ?? "")) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Color.gray.frame(width: 55, height: 75)
                                    }
                                }
                                .frame(width: 50, height: 75)
                                .cornerRadius(4)
                                
                                VStack(alignment: .leading) {
                                    Text(volume.name).font(.headline)
                                    Text(volume.publisher?.name ?? "Unknown Publisher").font(.caption).foregroundColor(.secondary)
                                    if let year = volume.start_year {
                                        Text(year).font(.caption2).foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Series")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
            .alert("Search Error", isPresented: $showingErrorAlert, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { }
            } message: { msg in
                Text(msg)
            }
            .onAppear {
                // Pre-fill query with filename
                query = cleanFilename(pdf.name)
            }
        }
    }
    
    func performSearch() {
        guard !query.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        
        if isBookMode {
            Task {
                do {
                    bookResults = try await BookMetadataService.shared.searchBooks(query: query)
                    isLoading = false
                } catch {
                    Logger.shared.log("BookVine Search Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                    await MainActor.run {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }
            return
        }
        
        let key = conversionManager.conversionSettings.comicVineAPIKey
        guard !key.isEmpty else {
            isLoading = false
            return
        }
        
        Task {
            do {
                comicResults = try await ComicVineService.shared.searchVolumes(query: query, apiKey: key)
                isLoading = false
            } catch {
                Logger.shared.log("Search Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                }
            }
        }
    }
    
    func selectBook(_ book: GoogleBookItem) {
        isLoading = true
        Task {
            await MainActor.run {
                var newMeta = pdf.metadata
                newMeta.title = book.volumeInfo.title
                newMeta.series = book.volumeInfo.subtitle
                newMeta.publisher = book.volumeInfo.publisher
                
                if let authors = book.volumeInfo.authors {
                    newMeta.writer = authors.joined(separator: ", ")
                }
                
                if let desc = book.volumeInfo.description {
                    newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                }
                
                if let dateString = book.volumeInfo.publishedDate {
                    let formatter = DateFormatter()
                    formatter.dateFormat = dateString.count == 4 ? "yyyy" : (dateString.count == 7 ? "yyyy-MM" : "yyyy-MM-dd")
                    newMeta.publicationDate = formatter.date(from: dateString)
                }
                
                newMeta.tags.append("Google Books")
                conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
                
                if let urlStr = book.volumeInfo.imageLinks?.bestQualityURL {
                    Task { await fetchAndSaveCover(urlStr) }
                } else {
                    dismiss()
                }
            }
        }
    }
    
    func selectVolume(_ volume: ComicVineVolume) {
        isLoading = true
        let originalSeries = pdf.metadata.series // Capture original to identify siblings
        Task {
            let key = conversionManager.conversionSettings.comicVineAPIKey
            do {
                // Try to guess issue number
                if let issueNum = extractIssueNumber(from: pdf.name) {
                     if let issue = try await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: issueNum, apiKey: key) {
                         await applyIssueMetadata(issue, volume: volume)
                         // Trigger intelligent background fetch
                         intelligentFetchRelatedIssues(for: volume, originalSeries: originalSeries)
                         return
                     }
                }
                
                // Fallback: Just apply Series info
                await applySeriesMetadata(volume)
                // Trigger intelligent background fetch
                intelligentFetchRelatedIssues(for: volume, originalSeries: originalSeries)
            } catch {
                Logger.shared.log("Metadata Fetch Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                }
            }
        }
    }
    
    func applyIssueMetadata(_ issue: ComicVineIssueDetails, volume: ComicVineVolume) async {
        await MainActor.run {
            var newMeta = pdf.metadata
            newMeta.title = issue.name ?? newMeta.title // Issues often don't have names, keeping old might be better or use Series #Num
            newMeta.series = volume.name
            newMeta.volume = issue.issue_number ?? newMeta.volume
            newMeta.issueNumber = issue.issue_number
            newMeta.publisher = volume.publisher?.name
            
            // Fix: Parse Date String (YYYY-MM-DD)
            if let dateString = issue.cover_date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                newMeta.publicationDate = formatter.date(from: dateString)
            }
            
            newMeta.summary = issue.description?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil) ?? ""
            newMeta.tags.append("ComicVine")
            
            if let credits = issue.person_credits {
                let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }.joined(separator: ", ")
                let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }.joined(separator: ", ")
                newMeta.writer = writers.isEmpty ? nil : writers
                newMeta.penciller = pencillers.isEmpty ? nil : pencillers
            }
            
            conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
             // Fetch cover if available?
             if let url = issue.image?.original_url {
                 Task { await fetchAndSaveCover(url) }
             }
            dismiss()
        }
    }
    
    func applySeriesMetadata(_ volume: ComicVineVolume) async {
        await MainActor.run {
            var newMeta = pdf.metadata
            newMeta.series = volume.name
            newMeta.publisher = volume.publisher?.name
            newMeta.tags.append("ComicVine")
            
            conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
            dismiss()
        }
    }
    
    func fetchAndSaveCover(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        if let data = try? Data(contentsOf: url) {
             await MainActor.run {
                 conversionManager.saveCoverImage(data, for: pdf)
                 conversionManager.saveLibrary()
             }
        }
    }
    
    // MARK: - Intelligent Series Fetch
    // Silently updates metadata for all other files that shared the same original series grouping.
    private func intelligentFetchRelatedIssues(for volume: ComicVineVolume, originalSeries: String?) {
        guard let oldSeriesName = originalSeries, !oldSeriesName.isEmpty else { return }
        
        let relatedFiles = conversionManager.convertedPDFs.filter {
            $0.metadata.series == oldSeriesName && $0.id != pdf.id
        }
        guard !relatedFiles.isEmpty else { return }
        
        let apiKey = conversionManager.conversionSettings.comicVineAPIKey
        let managerInfo = conversionManager // Explicit capture for the Task
        
        Task.detached(priority: .background) {
            for relatedPdf in relatedFiles {
                var newMeta = relatedPdf.metadata
                
                // Always inherit the series data
                newMeta.series = volume.name
                newMeta.publisher = volume.publisher?.name
                if !newMeta.tags.contains("ComicVine") {
                    newMeta.tags.append("ComicVine")
                }
                
                // Try to fetch specific issue data
                if let issueString = MetadataHeuristics.extractIssueNumber(from: relatedPdf.name),
                   let issue = try? await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: issueString, apiKey: apiKey) {
                    
                    newMeta.title = issue.name ?? newMeta.title
                    newMeta.volume = issue.issue_number ?? newMeta.volume
                    newMeta.issueNumber = issue.issue_number
                    
                    if let dateString = issue.cover_date {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        newMeta.publicationDate = formatter.date(from: dateString)
                    }
                    if let desc = issue.description {
                        newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                    }
                    if let credits = issue.person_credits {
                        let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }.joined(separator: ", ")
                        let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }.joined(separator: ", ")
                        newMeta.writer = writers.isEmpty ? nil : writers
                        newMeta.penciller = pencillers.isEmpty ? nil : pencillers
                    }
                }
                
                // Apply update on MainActor immediately so UI reflects it
                let finalMeta = newMeta
                await MainActor.run {
                    managerInfo.updatePDFMetadata(relatedPdf, metadata: finalMeta)
                }
            }
        }
    }
    
    // MARK: - Helpers
    func cleanFilename(_ name: String) -> String {
        var clean = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        clean = clean.replacingOccurrences(of: "_", with: " ")
        if let range = clean.range(of: "\\(.*?\\)", options: .regularExpression) {
             clean.removeSubrange(range)
        }
        return clean.trimmingCharacters(in: .whitespaces)
    }
    
    func extractIssueNumber(from name: String) -> String? {
        let pattern = "#?(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
            if let range = Range(match.range(at: 1), in: name) {
                return String(name[range])
            }
        }
        return nil
    }
}
