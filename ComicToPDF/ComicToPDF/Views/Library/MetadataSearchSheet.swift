import SwiftUI

struct MetadataSearchSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let pdf: ConvertedPDF
    @StateObject private var service = ComicVineService()
    
    @State private var query = ""
    @State private var results: [CVIssue] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack {
                // Search Bar
                HStack {
                    TextField("Series Name & Issue (e.g. Saga 10)", text: $query)
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
                if service.apiKey.isEmpty {
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
                    List(results) { issue in
                        Button(action: { applyMetadata(issue) }) {
                            HStack {
                                // Async Image for Result Preview
                                AsyncImage(url: URL(string: issue.image?.small_url ?? "")) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Color.gray.frame(width: 55, height: 75) // Adjusted width for better look
                                    }
                                }
                                .frame(width: 50, height: 75)
                                .cornerRadius(4)
                                
                                VStack(alignment: .leading) {
                                    Text(issue.fullTitle).font(.headline)
                                    Text(issue.cover_date ?? "Unknown Date").font(.caption).foregroundColor(.secondary)
                                    if let desc = issue.description {
                                        Text(desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)) // Strip HTML
                                            .font(.caption2)
                                            .lineLimit(2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Metadata")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                // Pre-fill query with filename
                query = pdf.name.replacingOccurrences(of: "_", with: " ")
                // Load API Key from Settings
                service.apiKey = conversionManager.conversionSettings.comicVineAPIKey
            }
        }
    }
    
    func performSearch() {
        guard !query.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                results = try await service.searchIssues(query: query)
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    func applyMetadata(_ issue: CVIssue) {
        isLoading = true
        Task {
            // 1. Fetch High-Res Cover
            var coverData: Data? = nil
            if let url = issue.image?.original_url {
                if let image = try? await service.fetchCoverImage(url: url) {
                    coverData = image.jpegData(compressionQuality: 0.7)
                }
            }
            
            // 2. Update PDF Metadata
            var newMeta = pdf.metadata
            newMeta.title = issue.name ?? newMeta.title
            newMeta.series = issue.volume?.name ?? newMeta.series
            newMeta.volume = issue.issue_number ?? newMeta.volume
            newMeta.publisher = "ComicVine Fetched"
            newMeta.summary = issue.description?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil) ?? ""
            newMeta.tags.append("ComicVine")
            
            await MainActor.run {
                // Update Metadata
                conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
                
                // Update Cover Art
                if let data = coverData {
                    conversionManager.saveCoverImage(data, for: pdf)
                    conversionManager.savePDFs()
                }
                
                dismiss()
            }
        }
    }
}
