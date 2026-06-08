import SwiftUI

struct BatchMetadataItem: Identifiable {
    let id: UUID
    var pdf: ConvertedPDF
    var status: Status = .waiting
    var message: String = ""
    
    // ✅ Editable Pre-Flight Staging Queries
    var editIssueNumber: String
    
    enum Status: String {
        case waiting = "Waiting"
        case searching = "Searching..."
        case matched = "Matched!"
        case partialMatch = "Partial Match"
        case failed = "Failed"
        case ignored = "Ignored"
    }
}

struct BatchSeriesGroup: Identifiable {
    let id = UUID()
    var seriesName: String
    var items: [BatchMetadataItem]
    var isExpanded: Bool = true
}

@MainActor
class BatchMetadataFetcher: ObservableObject {
    @Published var seriesGroups: [BatchSeriesGroup] = []
    
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
        
        var groupsDict: [String: [BatchMetadataItem]] = [:]
        for pdf in pdfs {
            let series = MetadataHeuristics.cleanFilename(pdf.name)
            let issue = MetadataHeuristics.extractIssueNumber(from: pdf.name) ?? ""
            let item = BatchMetadataItem(id: pdf.id, pdf: pdf, editIssueNumber: issue)
            groupsDict[series, default: []].append(item)
        }
        
        let sortedKeys = groupsDict.keys.sorted()
        self.seriesGroups = sortedKeys.map { key in
            BatchSeriesGroup(seriesName: key, items: groupsDict[key]!.sorted { $0.pdf.name < $1.pdf.name })
        }
    }
    
    func startExecution() async {
        currentPhase = .executing
        let apiKey = AppSettingsManager.shared.conversionSettings.comicVineAPIKey
        let deepFetch = AppSettingsManager.shared.conversionSettings.deepFetchComicVineIssues
        
        var volumeCache: [String: ComicVineVolume] = [:]
        var volumeIssuesCache: [Int: [ComicVineIssueDetails]] = [:]
        
        for groupIndex in seriesGroups.indices {
            let query = seriesGroups[groupIndex].seriesName
            
            let activeItemsCount = seriesGroups[groupIndex].items.filter { $0.status != .ignored }.count
            if activeItemsCount == 0 {
                for index in seriesGroups[groupIndex].items.indices {
                    let item = seriesGroups[groupIndex].items[index]
                    if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == item.id }) {
                        conversionManager.convertedPDFs[idx].metadata.autoMatchFailed = true
                    }
                    conversionManager.failedMetadataPDFs.removeAll(where: { $0.id == item.id })
                }
                conversionManager.saveLibrary()
                continue
            }
            
            for index in seriesGroups[groupIndex].items.indices {
                if seriesGroups[groupIndex].items[index].status != .ignored {
                    seriesGroups[groupIndex].items[index].status = .searching
                }
            }
            
            guard let firstActiveItem = seriesGroups[groupIndex].items.first(where: { $0.status != .ignored }) else { continue }
            let type = firstActiveItem.pdf.contentType
            
            var bestManga: MangaDexManga?
            var bestBook: GoogleBookItem?
            var bestVolume: ComicVineVolume?
            var groupError: String?
            
            do {
                if type == .manga {
                    let results = try await MangaDexService.shared.searchManga(query: query)
                    bestManga = results.first
                } else if type == .book {
                    let results = try await BookMetadataService.shared.searchBooks(query: query)
                    bestBook = results.first
                } else {
                    guard !apiKey.isEmpty else {
                        groupError = "No API Key found"
                        throw NSError(domain: "", code: 0) // bypass
                    }
                    
                    if let cached = volumeCache[query] {
                        bestVolume = cached
                    } else {
                        try? await Task.sleep(nanoseconds: 1_100_000_000)
                        let results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: apiKey)
                        bestVolume = results.first
                        if let v = bestVolume { volumeCache[query] = v }
                    }
                }
            } catch {
                groupError = error.localizedDescription
                aggregatedErrors.append("Error on \\(query): \\(error.localizedDescription)")
                if let vineError = error as? ComicVineError, case .rateLimited = vineError {
                    aggregatedErrors.append("Aborted remaining queue due to ComicVine rate limits.")
                    break
                }
            }
            
            for index in seriesGroups[groupIndex].items.indices {
                if seriesGroups[groupIndex].items[index].status == .ignored { continue }
                
                let issueStr = seriesGroups[groupIndex].items[index].editIssueNumber
                
                if let err = groupError {
                    seriesGroups[groupIndex].items[index].status = .failed
                    seriesGroups[groupIndex].items[index].message = err
                    continue
                }
                
                if type == .manga {
                    if let manga = bestManga {
                        applyMangaMatch(to: groupIndex, itemIndex: index, manga: manga)
                        seriesGroups[groupIndex].items[index].status = .matched
                        seriesGroups[groupIndex].items[index].message = "MangaDex Matched!"
                    } else {
                        seriesGroups[groupIndex].items[index].status = .failed
                        seriesGroups[groupIndex].items[index].message = "No MangaDex match."
                    }
                } else if type == .book {
                    if let book = bestBook {
                        applyBookMatch(to: groupIndex, itemIndex: index, book: book)
                        seriesGroups[groupIndex].items[index].status = .matched
                        seriesGroups[groupIndex].items[index].message = "Google Books Matched!"
                    } else {
                        seriesGroups[groupIndex].items[index].status = .failed
                        seriesGroups[groupIndex].items[index].message = "No Google Books match."
                    }
                } else {
                    if let volume = bestVolume {
                        seriesGroups[groupIndex].items[index].message = "Found Volume..."
                        
                        if deepFetch, !issueStr.isEmpty, let issueNum = Int(issueStr) {
                            do {
                                if volumeIssuesCache[volume.id] == nil {
                                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                                    let bulkIssues = try await ComicVineService.shared.getIssuesForVolume(volumeID: volume.id, apiKey: apiKey)
                                    volumeIssuesCache[volume.id] = bulkIssues.results
                                }
                                
                                let allIssues = volumeIssuesCache[volume.id] ?? []
                                if let issue = allIssues.first(where: { $0.issue_number == "\\(issueNum)" }) {
                                    applyFullMatch(to: groupIndex, itemIndex: index, volume: volume, issue: issue, issueNum: issueNum)
                                    seriesGroups[groupIndex].items[index].status = .matched
                                    seriesGroups[groupIndex].items[index].message = "Deep Fetch (Cached) matched!"
                                } else {
                                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                                    if let issue = try await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: "\\(issueNum)", apiKey: apiKey) {
                                        applyFullMatch(to: groupIndex, itemIndex: index, volume: volume, issue: issue, issueNum: issueNum)
                                        volumeIssuesCache[volume.id]?.append(issue)
                                        seriesGroups[groupIndex].items[index].status = .matched
                                        seriesGroups[groupIndex].items[index].message = "Deep Fetch matched!"
                                    } else {
                                        applyPartialMatch(to: groupIndex, itemIndex: index, volume: volume, issueNum: issueNum)
                                        seriesGroups[groupIndex].items[index].status = .partialMatch
                                        seriesGroups[groupIndex].items[index].message = "Series found, Issue missing."
                                    }
                                }
                            } catch {
                                seriesGroups[groupIndex].items[index].status = .failed
                                seriesGroups[groupIndex].items[index].message = error.localizedDescription
                            }
                        } else {
                            let iNum = Int(issueStr)
                            applyPartialMatch(to: groupIndex, itemIndex: index, volume: volume, issueNum: iNum)
                            seriesGroups[groupIndex].items[index].status = .partialMatch
                            seriesGroups[groupIndex].items[index].message = deepFetch ? "Series found, no issue provided." : "Fast Grouped to Series!"
                        }
                    } else {
                        seriesGroups[groupIndex].items[index].status = .failed
                        seriesGroups[groupIndex].items[index].message = "No ComicVine match."
                    }
                }
                
                let status = seriesGroups[groupIndex].items[index].status
                if status == .matched || status == .partialMatch {
                    let updatedPdf = seriesGroups[groupIndex].items[index].pdf
                    if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == updatedPdf.id }) {
                        conversionManager.convertedPDFs[idx] = updatedPdf
                    }
                    conversionManager.saveLibrary()
                }
            }
        }
        currentPhase = .finished
    }
    
    private func applyMangaMatch(to groupIndex: Int, itemIndex: Int, manga: MangaDexManga) {
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.series = manga.attributes.title["en"] ?? manga.attributes.title.values.first
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.universalSeriesID = manga.id
        if let year = manga.attributes.year {
            var comps = DateComponents()
            comps.year = year
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.publicationDate = Calendar.current.date(from: comps)
        }
        if let desc = manga.attributes.description {
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.summary = desc["en"] ?? desc.values.first
        }
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.tags.append("MangaDex")
    }
    
    private func applyBookMatch(to groupIndex: Int, itemIndex: Int, book: GoogleBookItem) {
        let info = book.volumeInfo
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.title = info.title
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.universalSeriesID = book.id
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.publisher = info.publisher
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.writer = info.authors?.joined(separator: ", ")
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.summary = info.description
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.tags.append("Google Books")
    }
    
    private func applyPartialMatch(to groupIndex: Int, itemIndex: Int, volume: ComicVineVolume, issueNum: Int?) {
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.series = volume.name
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.universalSeriesID = String(volume.id)
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.volume = volume.name
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.publisher = volume.publisher?.name
        
        if let num = issueNum {
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.issueNumber = "\\(num)"
        }
    }
    
    private func applyFullMatch(to groupIndex: Int, itemIndex: Int, volume: ComicVineVolume, issue: ComicVineIssueDetails, issueNum: Int) {
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.series = volume.name
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.universalSeriesID = String(volume.id)
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.volume = volume.name
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.issueNumber = "\\(issueNum)"
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.publisher = volume.publisher?.name
        seriesGroups[groupIndex].items[itemIndex].pdf.metadata.universalIssueID = String(issue.id)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let dateString = issue.cover_date, let date = formatter.date(from: dateString) {
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.publicationDate = date
        }
        
        if let desc = issue.description {
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        }
        
        if let credits = issue.person_credits {
            let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }.joined(separator: ", ")
            let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }.joined(separator: ", ")
            
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.writer = writers.isEmpty ? nil : writers
            seriesGroups[groupIndex].items[itemIndex].pdf.metadata.penciller = pencillers.isEmpty ? nil : pencillers
        }
    }
}

struct BatchMetadataFetchView: View {
    let pdfs: [ConvertedPDF]
    @Environment(\\.dismiss) var dismiss
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
                let totalMatched = fetcher.seriesGroups.flatMap { $0.items }.filter { $0.status == .matched }.count
                Text("\\(totalMatched) perfectly matched.\\n\\(fetcher.aggregatedErrors.count) items had issues or partial matches.")
            }
        }
    }
    
    private var stagingView: some View {
        List {
            ForEach($fetcher.seriesGroups) { $group in
                Section {
                    if group.isExpanded {
                        ForEach($group.items) { $item in
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
                                    if item.pdf.contentType != .book {
                                        TextField("Issue #", text: $item.editIssueNumber)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 80)
                                            .keyboardType(.numberPad)
                                    }
                                    Spacer()
                                    Button {
                                        if item.status == .ignored {
                                            item.status = .waiting
                                        } else {
                                            item.status = .ignored
                                        }
                                    } label: {
                                        Image(systemName: item.status == .ignored ? "eye.slash.fill" : "eye")
                                            .foregroundColor(item.status == .ignored ? .red : .gray)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    HStack {
                        Button {
                            withAnimation {
                                group.isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundColor(.primary)
                                .font(.body.bold())
                                .frame(width: 20)
                        }
                        
                        TextField("Series Name", text: $group.seriesName)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textCase(nil)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private var executingView: some View {
        List {
            ForEach(fetcher.seriesGroups) { group in
                Section(header: Text(group.seriesName).font(.headline)) {
                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.pdf.name)
                                .font(.subheadline)
                            
                            HStack {
                                if item.status == .searching {
                                    ProgressView().scaleEffect(0.7)
                                }
                                
                                Text(item.status.rawValue)
                                    .font(.caption)
                                    .foregroundColor(color(for: item.status))
                                    .bold()
                                
                                if !item.message.isEmpty {
                                    Text("- " + item.message)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func color(for status: BatchMetadataItem.Status) -> Color {
        switch status {
        case .waiting: return .gray
        case .searching: return .blue
        case .matched: return .green
        case .partialMatch: return .orange
        case .failed: return .red
        case .ignored: return .gray
        }
    }
}

