import SwiftUI

struct MetadataSearchSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let pdf: ConvertedPDF
    // Service is now a singleton
    
    @State private var query = ""
    @State private var results: [ComicVineVolume] = [] // Changed from CVIssue to ComicVineVolume
    @State private var isLoading = false
    @State private var errorMessage: String?
    
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
                
                // API Key Warning
                if conversionManager.conversionSettings.comicVineAPIKey.isEmpty {
                    Text("⚠️ Please set ComicVine API Key in Settings")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.bottom)
                }
                
                // Results List
                if isLoading {
                    ProgressView()
                    Spacer()
                } else {
                    List(results) { volume in
                        Button(action: { selectVolume(volume) }) {
                            HStack {
                                // Async Image for Result Preview
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
            .onAppear {
                // Pre-fill query with filename
                query = cleanFilename(pdf.name)
            }
        }
    }
    
    func performSearch() {
        guard !query.isEmpty else { return }
        let key = conversionManager.conversionSettings.comicVineAPIKey
        guard !key.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: key)
                isLoading = false
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func selectVolume(_ volume: ComicVineVolume) {
        // In the new flow, selecting a volume implies we want to apply its series data
        // and try to find the issue number from the filename.
        
        isLoading = true
        Task {
            let key = conversionManager.conversionSettings.comicVineAPIKey
            // Try to guess issue number
            if let issueNum = extractIssueNumber(from: pdf.name) {
                 if let issue = try? await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: issueNum, apiKey: key) {
                     await applyIssueMetadata(issue, volume: volume)
                     return
                 }
            }
            
            // Fallback: Just apply Series info
            await applySeriesMetadata(volume)
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
