import SwiftUI

struct MetadataEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @State private var title: String
    @State private var author: String
    @State private var series: String
    @State private var issueNumber: String
    @State private var summary: String
    @State private var isManga: Bool
    @State private var isWebtoon: Bool
    
    @State private var showingContentEditor = false
    
    init(pdf: ConvertedPDF) {
        self.pdf = pdf
        // Initialize state from existing metadata
        _title = State(initialValue: pdf.metadata.title)
        _author = State(initialValue: pdf.metadata.author ?? "")
        _series = State(initialValue: pdf.metadata.series ?? "")
        _issueNumber = State(initialValue: pdf.metadata.issueNumber ?? "")
        _summary = State(initialValue: pdf.metadata.summary ?? "")
        _isManga = State(initialValue: pdf.metadata.isManga ?? false)
        _isWebtoon = State(initialValue: pdf.metadata.isWebtoon ?? false)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Book Details")) {
                    TextField("Title", text: $title)
                    TextField("Author / Creator", text: $author)
                    TextField("Series", text: $series)
                    TextField("Issue #", text: $issueNumber)
                        .keyboardType(.numbersAndPunctuation)
                }
                
                Section(header: Text("Reading Experience")) {
                    Toggle(isOn: $isManga) {
                        HStack {
                            Image(systemName: "book.fill")
                            VStack(alignment: .leading) {
                                Text("Manga Mode")
                                Text("Right-to-Left Reading").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Toggle(isOn: $isWebtoon) {
                        HStack {
                            Image(systemName: "iphone")
                            VStack(alignment: .leading) {
                                Text("Webtoon Mode")
                                Text("Vertical Scroll Optimized").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Section(header: Text("Description")) {
                    TextEditor(text: $summary)
                        .frame(height: 100)
                }
                
                Section(header: Text("Advanced")) {
                    Button(action: {
                        showingContentEditor = true
                    }) {
                        HStack {
                            Image(systemName: "scissors")
                                .foregroundColor(.red)
                            Text("Remove Pages / Chapters")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Metadata & Options")
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
        }
        .sheet(isPresented: $showingContentEditor) {
            BookContentEditorView(pdf: pdf)
        }
    }
    
    private func saveChanges() {
        var updatedMetadata = pdf.metadata
        updatedMetadata.title = title
        updatedMetadata.author = author.isEmpty ? nil : author
        updatedMetadata.series = series.isEmpty ? nil : series
        updatedMetadata.issueNumber = issueNumber.isEmpty ? nil : issueNumber
        updatedMetadata.summary = summary.isEmpty ? nil : summary
        updatedMetadata.isManga = isManga
        updatedMetadata.isWebtoon = isWebtoon
        
        // Save via Manager
        conversionManager.updatePDFMetadata(pdf, metadata: updatedMetadata)
        
        dismiss()
    }
}
