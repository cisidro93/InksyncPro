import SwiftUI

struct PanelExtractionView: View {
    let sourceImage: UIImage
    @State private var panels: [PanelExtractor.Panel] = []
    @State private var isExtracting = false
    @State private var extractionMode: PanelExtractor.ExtractionMode = .automatic
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Picker("Mode", selection: Binding(
                    get: { 
                        switch extractionMode {
                        case .automatic: return 0
                        case .grid(2, 2): return 1
                        case .grid(3, 3): return 2
                        default: return 0
                        }
                    },
                    set: { value in
                        switch value {
                        case 0: extractionMode = .automatic
                        case 1: extractionMode = .grid(rows: 2, columns: 2)
                        case 2: extractionMode = .grid(rows: 3, columns: 3)
                        default: extractionMode = .automatic
                        }
                    }
                )) {
                    Text("Automatic").tag(0)
                    Text("Grid 2x2").tag(1)
                    Text("Grid 3x3").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if isExtracting {
                    ProgressView("Detecting panels...")
                        .padding()
                } else if panels.isEmpty {
                    Image(uiImage: sourceImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                    
                    Button("Extract Panels") {
                        extractPanels()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
                            ForEach(Array(panels.enumerated()), id: \.offset) { index, panel in
                                VStack {
                                    Image(uiImage: panel.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .cornerRadius(8)
                                        .shadow(radius: 4)
                                    
                                    Text("Panel \(index + 1)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                    }
                    
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding()
                }
            }
            .navigationTitle("Panel Extraction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func extractPanels() {
        isExtracting = true
        
        Task {
            do {
                let extractedPanels = try await PanelExtractor.extractPanels(
                    from: sourceImage,
                    mode: extractionMode
                )
                
                await MainActor.run {
                    panels = extractedPanels
                    isExtracting = false
                }
            } catch {
                await MainActor.run {
                    isExtracting = false
                    print("Panel extraction failed: \(error)")
                }
            }
        }
    }
}
