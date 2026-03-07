import SwiftUI

struct BatchMetadataItem: Identifiable {
    let id: UUID
    let pdf: ConvertedPDF
    var status: Status = .waiting
    var message: String = ""
    
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
    @Published var isFinished = false
    @Published var isProcessing = false
    
    let conversionManager: ConversionManager
    
    init(pdfs: [ConvertedPDF], conversionManager: ConversionManager) {
        self.conversionManager = conversionManager
        self.items = pdfs.map { BatchMetadataItem(id: $0.id, pdf: $0) }
    }
    
    func start() async {
        isProcessing = true
        let apiKey = conversionManager.conversionSettings.comicVineAPIKey
        
        guard !apiKey.isEmpty else {
            for i in items.indices {
                items[i].status = .failed
                items[i].message = "No API Key found"
            }
            isProcessing = false
            isFinished = true
            return
        }
        
        for index in items.indices {
            // Check cancellation or unmount (not strictly implemented here, but loop allows it)
            items[index].status = .searching
            
            let pdf = items[index].pdf
            let query = MetadataHeuristics.cleanFilename(pdf.name)
            let issueStr = MetadataHeuristics.extractIssueNumber(from: pdf.name)
            
            do {
                // 1. Search for Volume
                let results = try await ComicVineService.shared.searchVolumes(query: query, apiKey: apiKey)
                
                if let bestVolume = results.first {
                    // Try to fetch issue details if we have an issue number
                    if let issueStr = issueStr, let issueNum = Int(issueStr) {
                        items[index].message = "Found series, fetching issue #\(issueNum)..."
                        
                        if let issue = try await ComicVineService.shared.getIssue(volumeID: bestVolume.id, issueNumber: "\(issueNum)", apiKey: apiKey) {
                            applyFullMatch(to: index, volume: bestVolume, issue: issue, issueNum: issueNum)
                            items[index].status = .matched
                            items[index].message = "Fully matched!"
                        } else {
                            // Partial match
                            applyPartialMatch(to: index, volume: bestVolume, issueNum: issueNum)
                            items[index].status = .partialMatch
                            items[index].message = "Series found, Issue # missing."
                        }
                    } else {
                        // Partial match (no issue number in filename)
                        applyPartialMatch(to: index, volume: bestVolume, issueNum: nil)
                        items[index].status = .partialMatch
                        items[index].message = "Series found, no issue # in filename."
                    }
                } else {
                    items[index].status = .failed
                    items[index].message = "No matching series found."
                }
            } catch {
                items[index].status = .failed
                items[index].message = error.localizedDescription
            }
        }
        
        // Save to conversion manager
        for item in items where item.status == .matched || item.status == .partialMatch {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == item.id }) {
                conversionManager.convertedPDFs[idx] = item.pdf
            }
        }
        conversionManager.saveLibrary()
        
        isProcessing = false
        isFinished = true
    }
    
    private func applyPartialMatch(to index: Int, volume: ComicVineVolume, issueNum: Int?) {
        items[index].pdf.metadata.series = volume.name
        items[index].pdf.metadata.seriesID = volume.id
        items[index].pdf.metadata.volume = volume.name
        items[index].pdf.metadata.publisher = volume.publisher?.name
        
        if let num = issueNum {
            items[index].pdf.metadata.issueNumber = "\(num)"
        }
    }
    
    private func applyFullMatch(to index: Int, volume: ComicVineVolume, issue: ComicVineIssueDetails, issueNum: Int) {
        items[index].pdf.metadata.series = volume.name
        items[index].pdf.metadata.seriesID = volume.id
        items[index].pdf.metadata.volume = volume.name
        items[index].pdf.metadata.issueNumber = "\(issueNum)"
        items[index].pdf.metadata.publisher = volume.publisher?.name
        items[index].pdf.metadata.comicVineID = issue.id
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let dateString = issue.cover_date, let date = formatter.date(from: dateString) {
            items[index].pdf.metadata.publicationDate = date
        }
        
        if let desc = issue.description {
            items[index].pdf.metadata.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        }
        
        if let credits = issue.person_credits {
            let writers = credits.filter { $0.role.contains("Writer") }.map { $0.name }.joined(separator: ", ")
            let pencillers = credits.filter { $0.role.contains("Penciller") || $0.role.contains("Artist") }.map { $0.name }.joined(separator: ", ")
            
            items[index].pdf.metadata.writer = writers.isEmpty ? nil : writers
            items[index].pdf.metadata.penciller = pencillers.isEmpty ? nil : pencillers
        }
    }
}

struct BatchMetadataFetchView: View {
    let pdfs: [ConvertedPDF]
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @StateObject private var fetcher: BatchMetadataFetcher
    
    init(pdfs: [ConvertedPDF], conversionManager: ConversionManager) {
        self.pdfs = pdfs
        self._fetcher = StateObject(wrappedValue: BatchMetadataFetcher(pdfs: pdfs, conversionManager: conversionManager))
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(fetcher.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.pdf.name)
                            .font(.headline)
                        
                        HStack {
                            Text(item.status.rawValue)
                                .font(.subheadline)
                                .foregroundColor(color(for: item.status))
                                .bold()
                            
                            if !item.message.isEmpty {
                                Text("- " + item.message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Batch Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if fetcher.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                } else if !fetcher.isProcessing {
                     ToolbarItem(placement: .cancellationAction) {
                         Button("Cancel") {
                             dismiss()
                         }
                     }
                }
            }
            .task {
                if !fetcher.isProcessing && !fetcher.isFinished {
                    await fetcher.start()
                }
            }
            .interactiveDismissDisabled(fetcher.isProcessing)
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
