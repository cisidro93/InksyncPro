import SwiftUI

struct BatchMetadataEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let selectedPDFs: [ConvertedPDF]
    
    // Form State (Only fields that will be applied to ALL selected files)
    @AppStorage("batchLastAuthor") private var author: String = ""
    @AppStorage("batchLastPublisher") private var publisher: String = ""
    @AppStorage("batchLastSeries") private var series: String = ""
    @State private var tags: [String] = []
    
    // Apply Toggles (User chooses which fields to actually overwrite)
    @State private var applyAuthor = false
    @State private var applyPublisher = false
    @State private var applySeries = false
    @State private var applyTags = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Target Files")) {
                    Text("Editing \(selectedPDFs.count) files")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Fields to Update"), footer: Text("Only fields with the toggle enabled will be applied to the selected files. Empty text fields will clear the data if applied.")) {
                    
                    // Series
                    Toggle(isOn: $applySeries.animation()) {
                        TextField("Series Name", text: $series)
                            .disabled(!applySeries)
                            .foregroundColor(applySeries ? .primary : .secondary)
                    }
                    
                    // Publisher
                    Toggle(isOn: $applyPublisher.animation()) {
                        TextField("Publisher", text: $publisher)
                            .disabled(!applyPublisher)
                            .foregroundColor(applyPublisher ? .primary : .secondary)
                    }
                    
                    // Author
                    Toggle(isOn: $applyAuthor.animation()) {
                        TextField("Author / Writer", text: $author)
                            .disabled(!applyAuthor)
                            .foregroundColor(applyAuthor ? .primary : .secondary)
                    }
                }
                
                Section(header: Text("Batch Tags")) {
                    Toggle("Apply these tags", isOn: $applyTags.animation())
                    
                    if applyTags {
                        TagEditorView(tags: $tags)
                    }
                }
            }
            .navigationTitle("Batch Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply to All") {
                        applyBatchChanges()
                    }
                    .fontWeight(.bold)
                    // Disable save if no toggles are on
                    .disabled(!applySeries && !applyPublisher && !applyAuthor && !applyTags)
                }
            }
            .onAppear { prefillSharedValues() }
        }
    }
    
    // MARK: - Pre-fill Logic
    private func prefillSharedValues() {
        guard !selectedPDFs.isEmpty else { return }
        
        // Check if all selected files share the same series
        let firstSeries = selectedPDFs.first?.metadata.series
        if let s = firstSeries, !s.isEmpty, selectedPDFs.allSatisfy({ $0.metadata.series == s }) {
            self.series = s
        }
        
        // Check if all selected files share the same publisher
        let firstPublisher = selectedPDFs.first?.metadata.publisher
        if let p = firstPublisher, !p.isEmpty, selectedPDFs.allSatisfy({ $0.metadata.publisher == p }) {
            self.publisher = p
        }
        
        // Check if all selected files share the same author
        let firstAuthor = selectedPDFs.first?.metadata.writer
        if let a = firstAuthor, !a.isEmpty, selectedPDFs.allSatisfy({ $0.metadata.writer == a }) {
            self.author = a
        }
    }
    
    private func applyBatchChanges() {
        for pdf in selectedPDFs {
            var updatedMeta = pdf.metadata
            
            if applySeries { updatedMeta.series = series.isEmpty ? nil : series }
            if applyPublisher { updatedMeta.publisher = publisher.isEmpty ? nil : publisher }
            if applyAuthor { updatedMeta.writer = author.isEmpty ? nil : author }
            if applyTags { updatedMeta.tags = tags }
            
            // Note: In a true architecture, ConversionManager should have an `updateMetadata(for:with:)` 
            // that accepts an array, but we'll loop for now and save once.
            if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[index].metadata = updatedMeta
                
                // If series was updated, handle grouping Logic
                if applySeries {
                    let seriesName = series.isEmpty ? "Unknown" : series
                    if let existingCol = conversionManager.collections.first(where: { $0.name == seriesName }) {
                        conversionManager.convertedPDFs[index].collectionId = existingCol.id
                    } else if !seriesName.isEmpty && seriesName != "Unknown" {
                        let newCol = PDFCollection(id: UUID(), name: seriesName, icon: "folder", color: "blue", creationDate: Date())
                        conversionManager.collections.append(newCol)
                        conversionManager.convertedPDFs[index].collectionId = newCol.id
                    }
                }
                
                // ✅ Write back to CBZ
                if pdf.url.pathExtension.lowercased() == "cbz" || pdf.url.pathExtension.lowercased() == "zip" {
                    Task {
                        do {
                            try await ComicInfoWriter.write(metadata: updatedMeta, to: pdf.url)
                        } catch {
                            Logger.shared.log("Batch Editor: Failed to write to archive \(pdf.name): \(error.localizedDescription)", category: "Metadata", type: .warning)
                        }
                    }
                }
            }
        }
        
        conversionManager.saveLibrary()
        conversionManager.scanLibrary()
        
        dismiss()
    }
}
