import SwiftUI

struct CognitiveBatchItem: Identifiable {
    let id: UUID
    var pdf: ConvertedPDF
    var status: Status = .waiting
    var message: String = ""
    
    enum Status: String {
        case waiting = "Waiting"
        case extracting = "AI Extracting..."
        case applying = "Applying Metadata..."
        case renaming = "Renaming File..."
        case finished = "Done ✨"
        case failed = "Failed"
    }
}

@MainActor
class CognitiveBatchFetcher: ObservableObject {
    @Published var items: [CognitiveBatchItem] = []
    @Published var isFinished = false
    @Published var isProcessing = false
    
    let conversionManager: ConversionManager
    let autoRenamePhysicalFiles: Bool
    
    init(pdfs: [ConvertedPDF], conversionManager: ConversionManager, autoRenamePhysicalFiles: Bool) {
        self.conversionManager = conversionManager
        self.autoRenamePhysicalFiles = autoRenamePhysicalFiles
        self.items = pdfs.map { CognitiveBatchItem(id: $0.id, pdf: $0) }
    }
    
    func start() async {
        isProcessing = true
        let apiKey = conversionManager.conversionSettings.openAIAPIKey
        
        guard !apiKey.isEmpty else {
            for i in items.indices {
                items[i].status = .failed
                items[i].message = "Missing OpenAI API Key."
            }
            isProcessing = false; isFinished = true
            return
        }
        
        // Process sequentially to respect OpenAI Vision rate limits perfectly
        for index in items.indices {
            // Safety break check is internal
            items[index].status = .extracting
            let pdf = items[index].pdf
            let coverURL = conversionManager.getCoverURL(for: pdf)
            
            do {
                let aiResult = try await CognitiveMetadataService.shared.extractMetadata(filename: pdf.name, coverURL: coverURL, apiKey: apiKey)
                
                items[index].status = .applying
                
                // Construct new internal metadata
                var newMeta = pdf.metadata
                newMeta.series = aiResult.series ?? newMeta.series
                newMeta.title = aiResult.title ?? newMeta.title
                newMeta.issueNumber = aiResult.issueNumber ?? newMeta.issueNumber
                newMeta.publisher = aiResult.publisher ?? newMeta.publisher
                if let y = aiResult.publicationYear { newMeta.tags.append(y) }
                if !newMeta.tags.contains("AI Extracted") { newMeta.tags.append("AI Extracted") }
                
                items[index].pdf.metadata = newMeta
                
                // Track into permanent ConversionManager immediately
                if let cmIdx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[cmIdx] = items[index].pdf
                }
                
                if autoRenamePhysicalFiles, let s = aiResult.series, let i = aiResult.issueNumber {
                    items[index].status = .renaming
                    let cleanFilename = "\(s) #\(i)"
                    try conversionManager.safelyRenamePhysicalFile(pdf: items[index].pdf, newName: cleanFilename)
                    
                    // Re-sync pointer into local loop so UI updates
                    if let freshPdf = conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) {
                        items[index].pdf = freshPdf
                    }
                }
                
                items[index].status = .finished
                if let s = aiResult.series, let i = aiResult.issueNumber {
                    items[index].message = "Extracted: \(s) #\(i)"
                } else {
                    items[index].message = "Extracted partial data."
                }
                
            } catch {
                items[index].status = .failed
                items[index].message = error.localizedDescription
            }
            
            // Brief 1.5s pause to prevent rapid-fire GPT-4o 429 Rate Limits
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        
        conversionManager.saveLibrary()
        isProcessing = false
        isFinished = true
    }
}

struct CognitiveBatchRenamerView: View {
    let pdfs: [ConvertedPDF]
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var autoRename = true
    @State private var hasStarted = false
    
    // We defer object creation until `hasStarted`
    @StateObject private var fetcherContainer = ObservableContainer()
    
    class ObservableContainer: ObservableObject {
        @Published var fetcher: CognitiveBatchFetcher?
    }
    
    var body: some View {
        NavigationView {
            VStack {
                if !hasStarted {
                    instructionView
                } else if let fetcher = fetcherContainer.fetcher {
                    List {
                        ForEach(fetcher.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.pdf.name).font(.headline)
                                HStack {
                                    Text(item.status.rawValue)
                                        .font(.subheadline)
                                        .foregroundColor(color(for: item.status))
                                        .bold()
                                    if !item.message.isEmpty {
                                        Text("- " + item.message).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(hasStarted ? "AI Renaming" : "Cognitive AI Renamer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let f = fetcherContainer.fetcher, f.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else if !hasStarted || !(fetcherContainer.fetcher?.isProcessing ?? false) {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(fetcherContainer.fetcher?.isProcessing == true)
        }
    }
    
    private var instructionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 80))
                .foregroundColor(.purple)
                .padding(.top, 40)
            
            Text("Extract & Correct \(pdfs.count) Books")
                .font(.title2.bold())
            
            Text("The Vision AI will explicitly read the text printed on the cover art of your selected comics to permanently fix scrambled or randomized filenames.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 30)
            
            Toggle("Permanently Rename Physical Files", isOn: $autoRename)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal, 30)
            
            Button(action: {
                startBatch()
            }) {
                Label("Begin AI Scan", systemImage: "play.fill")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 40)
            .padding(.top, 10)
            
            Spacer()
        }
    }
    
    private func startBatch() {
        hasStarted = true
        let fetcher = CognitiveBatchFetcher(pdfs: pdfs, conversionManager: conversionManager, autoRenamePhysicalFiles: autoRename)
        fetcherContainer.fetcher = fetcher
        
        Task {
            await fetcher.start()
        }
    }
    
    private func color(for status: CognitiveBatchItem.Status) -> Color {
        switch status {
        case .waiting: return .gray
        case .extracting, .applying: return .purple
        case .renaming: return .blue
        case .finished: return .green
        case .failed: return .red
        }
    }
}
