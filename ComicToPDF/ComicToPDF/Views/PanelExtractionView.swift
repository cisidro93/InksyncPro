import SwiftUI

struct PanelExtractionView: View {
    let image: UIImage
    @State private var extractedPanels: [UIImage] = []
    @State private var isProcessing = false
    @State private var extractionMode: PanelExtractor.ExtractionMode = .automatic
    @State private var showSaveSuccess = false
    
    // Grid settings
    @State private var gridRows = 2
    @State private var gridCols = 2
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                if extractedPanels.isEmpty && !isProcessing {
                    // Preview Original
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else if isProcessing {
                    ProgressView("Extracting Panels...")
                } else {
                    // Result Grid
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                            ForEach(0..<extractedPanels.count, id: \.self) { index in
                                VStack {
                                    Image(uiImage: extractedPanels[index])
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: 150)
                                        .cornerRadius(8)
                                    Text("Panel \(index + 1)")
                                        .font(.caption)
                                }
                            }
                        }
                        .padding()
                    }
                }
                
                // Controls
                VStack {
                    Picker("Mode", selection: Binding(get: {
                        switch extractionMode {
                        case .automatic: return 0
                        case .grid: return 1
                        case .manual: return 2
                        }
                    }, set: { val in
                        if val == 0 { extractionMode = .automatic }
                        else if val == 1 { extractionMode = .grid(rows: gridRows, cols: gridCols) }
                        else { extractionMode = .manual }
                    })) {
                        Text("Automatic").tag(0)
                        Text("Grid").tag(1)
                        Text("Manual").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    
                    if case .grid = extractionMode {
                        HStack {
                            Stepper("Rows: \(gridRows)", value: $gridRows, in: 1...5)
                            Stepper("Cols: \(gridCols)", value: $gridCols, in: 1...4)
                        }
                        .padding(.horizontal)
                        .onChange(of: gridRows) { _ in updateGridMode() }
                        .onChange(of: gridCols) { _ in updateGridMode() }
                    }
                    
                    Button("Extract Panels") {
                        processExtraction()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                    
                    if !extractedPanels.isEmpty {
                        Button("Save Panels to Photos") {
                            savePanels()
                        }
                        .padding(.bottom)
                    }
                }
                .background(Color(UIColor.secondarySystemBackground))
            }
            .navigationTitle("Panel Extractor")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Success", isPresented: $showSaveSuccess) {
                Button("OK") { }
            } message: {
                Text("Panels saved to Photos.")
            }
        }
    }
    
    private func updateGridMode() {
        extractionMode = .grid(rows: gridRows, cols: gridCols)
    }
    
    private func processExtraction() {
        isProcessing = true
        extractedPanels = []
        Task {
            do {
                // Ensure grid mode params are current
                if case .grid = extractionMode {
                    extractionMode = .grid(rows: gridRows, cols: gridCols)
                }
                
                let panels = try await PanelExtractor.extractPanels(from: image, mode: extractionMode)
                await MainActor.run {
                    self.extractedPanels = panels
                    self.isProcessing = false
                }
            } catch {
                print("Error: \(error)")
                await MainActor.run { isProcessing = false }
            }
        }
    }
    
    private func savePanels() {
        for panel in extractedPanels {
            UIImageWriteToSavedPhotosAlbum(panel, nil, nil, nil)
        }
        showSaveSuccess = true
    }
}
