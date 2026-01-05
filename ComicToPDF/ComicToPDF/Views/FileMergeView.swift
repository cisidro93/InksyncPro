import SwiftUI

struct FileMergeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State var filesToMerge: [ConvertedPDF]
    @State private var volumeTitle: String = ""
    @State private var optimizeForKindle: Bool = false
    @State private var isMerging = false
    @State private var mergeProgress: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Volume Details")) {
                    TextField("Volume Title (e.g. Batman Vol 1)", text: $volumeTitle)
                }
                
                Section(header: Text("Files (Drag to Reorder)")) {
                    List {
                        ForEach(filesToMerge) { pdf in
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundColor(.orange)
                                Text(pdf.name)
                                    .lineLimit(1)
                            }
                        }
                        .onMove { indices, newOffset in
                            filesToMerge.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                }
                
                Section(header: Text("Kindle Options"), footer: Text("Splits panels into separate pages for Kindle compatibility.")) {
                    Toggle("Optimize for Kindle", isOn: $optimizeForKindle)
                }
                
                if isMerging {
                    Section {
                        HStack {
                            ProgressView()
                            Text(mergeProgress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section {
                    Button(action: startMerge) {
                        Text("Create Volume")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                    .listRowBackground(volumeTitle.isEmpty ? Color.gray : Color.orange)
                    .disabled(volumeTitle.isEmpty || isMerging)
                }
            }
            .navigationTitle("Merge Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton() // Enables drag-and-drop
                }
            }
            .onAppear {
                if volumeTitle.isEmpty {
                    volumeTitle = filesToMerge.first?.name.replacingOccurrences(of: " #1", with: " Vol 1") ?? "New Volume"
                }
            }
        }
    }
    
    private func startMerge() {
        guard !volumeTitle.isEmpty else { return }
        isMerging = true
        mergeProgress = "Initializing..."
        
        Task {
            // 1. Configure Settings
            var settings = conversionManager.conversionSettings.epubSettings
            settings.splitPanels = optimizeForKindle
            // Disable smart view if splitting, as they are redundant
            if optimizeForKindle { settings.enablePanelView = false }
            
            // 2. Prepare Metadata
            var metadata = PDFMetadata()
            metadata.title = volumeTitle
            metadata.author = filesToMerge.first?.metadata.author
            
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(volumeTitle)
                .appendingPathExtension("epub")
            
            do {
                // 3. Run Merge
                let (finalURL, count) = try await EPUBMerger.mergeEPUBs(
                    sourceURLs: filesToMerge.map { $0.url },
                    outputURL: outputURL,
                    metadata: metadata,
                    settings: settings,
                    onStatusUpdate: { status in
                        Task { @MainActor in self.mergeProgress = status }
                    }
                )
                
                // 4. Save to Library
                await MainActor.run {
                    conversionManager.addConvertedPDF(
                        url: finalURL,
                        name: volumeTitle,
                        pageCount: count,
                        fileSize: (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                        metadata: metadata
                    )
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    mergeProgress = "Failed: \(error.localizedDescription)"
                    isMerging = false
                }
            }
        }
    }
}
