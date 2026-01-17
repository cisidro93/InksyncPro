import SwiftUI

struct BatchMergeReorderView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Input
    var sourceFiles: [ConvertedPDF]
    
    // State
    @State private var selectedFiles: [ConvertedPDF] = []
    @State private var mergedName: String = "Merged Collection"
    @State private var isProcessing = false
    
    var body: some View {
        NavigationView {
            VStack {
                if isProcessing {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(conversionManager.statusMessage ?? "Processing...")
                            .font(.headline)
                        Text(conversionManager.processingStatus)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Form {
                        Section(header: Text("Output Name")) {
                            TextField("Collection Name", text: $mergedName)
                        }
                        
                        Section(header: Text("Order (Drag to Reorder)")) {
                            List {
                                ForEach(selectedFiles) { file in
                                    HStack {
                                        Image(systemName: "doc.text")
                                        Text(file.name)
                                    }
                                }
                                .onMove { indices, newOffset in
                                    selectedFiles.move(fromOffsets: indices, toOffset: newOffset)
                                }
                            }
                        }
                        
                        Section(footer: Text("This will convert all selected files to EPUB and merge them into a single file. The individual files will be deleted after merging to save space.")) {
                            Button {
                                startMerge()
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Convert & Merge")
                                        .bold()
                                    Spacer()
                                }
                            }
                            .listRowBackground(Color.blue)
                            .foregroundColor(.white)
                        }
                    }
                }
            }
            .navigationTitle("Merge Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isProcessing {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !isProcessing {
                        EditButton() // Enables dragging in the list
                    }
                }
            }
            .onAppear {
                if selectedFiles.isEmpty {
                    selectedFiles = sourceFiles
                }
            }
        }
    }
    
    private func startMerge() {
        guard !selectedFiles.isEmpty else { return }
        isProcessing = true
        
        Task {
            // Call the manager to do the work
            await conversionManager.convertAndMerge(sourceFiles: selectedFiles, outputName: mergedName)
            
            await MainActor.run {
                isProcessing = false
                dismiss()
            }
        }
    }
}
