import SwiftUI

struct BatchMetadataItem: Identifiable {
    let id: UUID
    var pdf: ConvertedPDF
    var status: Status = .waiting
    var message: String = ""
    
    // ✅ Editable Pre-Flight Staging Queries
    var editSeriesName: String
    var editIssueNumber: String
    
    enum Status: String {
        case waiting = "Waiting"
        case searching = "Searching..."
        case matched = "Matched!"
        case partialMatch = "Partial Match"
        case failed = "Failed"
    }
}

@MainActor
class BatchMetadataFetcher: ObservableObject {
    @Published var items: [BatchMetadataItem] = []
    
    // ✅ Phase Tracking
    enum Phase {
        case staging
        case executing
        case finished
    }
    @Published var currentPhase: Phase = .staging
    @Published var aggregatedErrors: [String] = []
    
    let conversionManager: ConversionManager
    
    init(pdfs: [ConvertedPDF], conversionManager: ConversionManager) {
        self.conversionManager = conversionManager
        self.items = pdfs.map {
            let series = MetadataHeuristics.cleanFilename($0.name)
            let issue = MetadataHeuristics.extractIssueNumber(from: $0.name) ?? ""
            return BatchMetadataItem(id: $0.id, pdf: $0, editSeriesName: series, editIssueNumber: issue)
        }
    }
    
    func startExecution() async {
        currentPhase = .executing
        let apiKey = AppSettingsManager.shared.conversionSettings.comicVineAPIKey
        let deepFetch = AppSettingsManager.shared.conversionSettings.deepFetchComicVineIssues
        
        // Cache to prevent repetitive API calls for volume searches
        var volumeCache: [String: ComicVineVolume] = [:]
        var volumeIssuesCache: [Int: [ComicVineIssueDetails]] = [:]
        
        for index in items.indices {
            items[index].status = .searching
            
            let query = items[index].editSeriesName
            let issueStr = items[index].editIssueNumber
            let type = items[index].pdf.contentType
            
            do {
                if type == .manga {
                    let results = try await MangaDexService.shared.searchManga(query: query)
                    if let best = results.first {
                        applyMangaMatch(to: index, manga: best)
                        items[index].status = .matched
                        items[index].message = "MangaDex Matched!"
                    } else {
                        items[index].status = .failed
                        items[index].message = "No MangaDex match."
                    }
                } else if type == .book {
                    let results = try await BookMetadataService.shared.searchBooks(query: query)
                    if let best = results.first {
                        applyBookMatch(to: index, book: best)
                        items[index].status = .matched
                        items[index].message = "Google Books Matched!"
                    } else {
                        items[index].status = .failed
                        items[index].message = "No Google Books match."
                    }
                } else {
                    guard !apiKey.isEmpty else {
                        items[index].status = .failed
                        items[index].message = "No API Key found"
                        continue
                    }
                    
                    let bestVolume: ComicVineVolume?
                    if let cached = volumeCache[query] {
                        bestVolume = cached
                    } else {
                        try? await Task.sleep(nanoseconds: 1_100_000_000) // 1.1s pacing
                        let results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: apiKey)
                        bestVolume = results.first
                        if let v = bestVolume { volumeCache[query] = v }
                    }
                    
                    if let bestVolume = bestVolume {
                        items[index].message = "Found Volume '\(bestVolume.name)'..."
                        
                        if deepFetch, !issueStr.isEmpty, let issueNum = Int(issueStr) {
                            if volumeIssuesCache[bestVolume.id] == nil {
                                try? await Task.sleep(nanoseconds: 1_100_000_000) // 1.1s pacing
                                let bulkIssues = try await ComicVineService.shared.getIssuesForVolume(volumeID: bestVolume.id, apiKey: apiKey)
                                volumeIssuesCache[bestVolume.id] = bulkIssues.results
                            }
                            
                            let allIssues = volumeIssuesCache[bestVolume.id] ?? []
                            if let issue = allIssues.first(where: { $0.issue_number == "\(issueNum)" }) {
                                applyFullMatch(to: index, volume: bestVolume, issue: issue, issueNum: issueNum)
                                items[index].status = .matched
                                items[index].message = "Deep Fetch (Cached) matched!"
                            } else {
                                try? await Task.sleep(nanoseconds: 1_100_000_000) // 1.1s pacing
                                if let issue = try await ComicVineService.shared.getIssue(volumeID: bestVolume.id, issueNumber: "\(issueNum)", apiKey: apiKey) {
                                    applyFullMatch(to: index, volume: bestVolume, issue: issue, issueNum: issueNum)
                                    volumeIssuesCache[bestVolume.id]?.append(issue)
                                    items[index].status = .matched
                                    items[index].message = "Deep Fetch matched!"
                                } else {
                                    applyPartialMatch(to: index, volume: bestVolume, issueNum: issueNum)
                                    items[index].status = .partialMatch
                                    items[index].message = "Series found, Issue # missing."
                                }
                            }
                        } else {
                            let iNum = Int(issueStr)
                            applyPartialMatch(to: index, volume: bestVolume, issueNum: iNum)
                            items[index].status = .partialMatch
                            items[index].message = deepFetch ? "Series found, no issue provided." : "Fast Grouped to Series!"
                        }
                    } else {
                        items[index].status = .failed
                        items[index].message = "No ComicVine match."
                    }
                }
            } catch {
                items[index].status = .failed
                items[index].message = error.localizedDescription
                aggregatedErrors.append("Error on \(query): \(error.localizedDescription)")
                
                if let vineError = error as? ComicVineError, case .rateLimited = vineError {
                    aggregatedErrors.append("Aborted remaining queue due to ComicVine rate limits / cluster block.")
                    break
                }
            }
            
            // ✅ Incremental Save
            let status = items[index].status
            if status == .matched || status == .partialMatch {
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == items[index].id }) {
                    conversionManager.convertedPDFs[idx] = items[index].pdf
                }
                conversionManager.saveLibrary()
            }
        }
        
        currentPhase = .finished
    }
    
    private func applyMangaMatch(to index: Int, manga: MangaDexManga) {
        items[index].pdf.metadata.series = manga.attributes.title["en"] ?? manga.attributes.title.values.first
        items[index].pdf.metadata.universalSeriesID = manga.id
        if let year = manga.attributes.year {
            var comps = DateComponents()
            comps.year = year
            items[index].pdf.metadata.publicationDate = Calendar.current.date(from: comps)
        }
        if let desc = manga.attributes.description {
            items[index].pdf.metadata.summary = desc["en"] ?? desc.values.first
        }
        items[index].pdf.metadata.tags.append("MangaDex")
    }
    
    private func applyBookMatch(to index: Int, book: GoogleBookItem) {
        let info = book.volumeInfo
        items[index].pdf.metadata.title = info.title
        items[index].pdf.metadata.universalSeriesID = book.id
        items[index].pdf.metadata.publisher = info.publisher
        items[index].pdf.metadata.writer = info.authors?.joined(separator: ", ")
        items[index].pdf.metadata.summary = info.description
        items[index].pdf.metadata.tags.append("Google Books")
    }
    
    private func applyPartialMatch(to index: Int, volume: ComicVineVolume, issueNum: Int?) {
        items[index].pdf.metadata.series = volume.name
        items[index].pdf.metadata.universalSeriesID = String(volume.id)
        items[index].pdf.metadata.volume = volume.name
        items[index].pdf.metadata.publisher = volume.publisher?.name
        
        if let num = issueNum {
            items[index].pdf.metadata.issueNumber = "\(num)"
        }
    }
    
    private func applyFullMatch(to index: Int, volume: ComicVineVolume, issue: ComicVineIssueDetails, issueNum: Int) {
        items[index].pdf.metadata.series = volume.name
        items[index].pdf.metadata.universalSeriesID = String(volume.id)
        items[index].pdf.metadata.volume = volume.name
        items[index].pdf.metadata.issueNumber = "\(issueNum)"
        items[index].pdf.metadata.publisher = volume.publisher?.name
        items[index].pdf.metadata.universalIssueID = String(issue.id)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let dateString = issue.cover_date, let date = formatter.date(from: dateString) {
            items[index].pdf.metadata.publicationDate = date
        }
        
        if let desc = issue.description {
            items[index].pdf.metadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        }
        
        if let credits = issue.person_credits {
            let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }.joined(separator: ", ")
            let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }.joined(separator: ", ")
            
            items[index].pdf.metadata.writer = writers.isEmpty ? nil : writers
            items[index].pdf.metadata.penciller = pencillers.isEmpty ? nil : pencillers
        }
    }
}

struct BatchMetadataFetchView: View {
    let pdfs: [ConvertedPDF]
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    @StateObject private var fetcher: BatchMetadataFetcher
    @State private var showingErrorSummary = false
    
    init(pdfs: [ConvertedPDF], conversionManager: ConversionManager) {
        self.pdfs = pdfs
        self._fetcher = StateObject(wrappedValue: BatchMetadataFetcher(pdfs: pdfs, conversionManager: conversionManager))
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if fetcher.currentPhase == .staging {
                    stagingView
                } else {
                    executingView
                }
            }
            .navigationTitle(fetcher.currentPhase == .staging ? "Pre-Flight Review" : "Batch Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if fetcher.currentPhase == .finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                } else if fetcher.currentPhase == .staging {
                     ToolbarItem(placement: .cancellationAction) {
                         Button("Cancel") { dismiss() }
                     }
                     ToolbarItem(placement: .confirmationAction) {
                         Button("Start Fetching") {
                             Task { await fetcher.startExecution() }
                         }
                         .bold()
                     }
                }
            }
            .interactiveDismissDisabled(fetcher.currentPhase == .executing)
            .onChange(of: fetcher.currentPhase) { _, newPhase in
                if newPhase == .finished && !fetcher.aggregatedErrors.isEmpty {
                    showingErrorSummary = true
                }
            }
            .alert("Operation Summary", isPresented: $showingErrorSummary) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("\(fetcher.items.filter { $0.status == .matched }.count) perfectly matched.\n\(fetcher.aggregatedErrors.count) items had issues or partial matches.")
            }
        }
    }
    
    private var stagingView: some View {
        List {
            Section(header: Text("Verify Detected Info")) {
                ForEach($fetcher.items) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.pdf.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: item.pdf.contentType.icon)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            TextField("Series / Title Name", text: $item.editSeriesName)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            
                            if item.pdf.contentType != .book {
                                TextField("Issue #", text: $item.editIssueNumber)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .keyboardType(.numberPad)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private var executingView: some View {
        List {
            ForEach(fetcher.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.pdf.name)
                        .font(.headline)
                    
                    HStack {
                        if item.status == .searching {
                            ProgressView().scaleEffect(0.7)
                        }
                        
                        Text(item.status.rawValue)
                            .font(.subheadline)
                            .foregroundColor(color(for: item.status))
                            .bold()
                        
                        if !item.message.isEmpty {
                            Text("- " + item.message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private func color(for status: BatchMetadataItem.Status) -> Color {
        switch status {
        case .waiting: return .gray
        case .searching: return .blue
        case .matched: return .green
        case .partialMatch: return .orange
        case .failed: return .red
        }
    }
}
