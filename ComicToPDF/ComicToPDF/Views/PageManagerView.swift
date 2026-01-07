import SwiftUI

struct PageManagerView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    @State private var images: [UIImage] = []
    @State private var isLoading = true
    @State private var loadingProgress = 0.0
    
    // Selection Mode (For Deleting)
    @State private var isSelectionMode = false
    @State private var selectedIndices: Set<Int> = []
    
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    VStack {
                        ProgressView("Unpacking Comic...", value: loadingProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .padding()
                        Text("This may take a moment.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(0..<images.count, id: \.self) { index in
                                ZStack(alignment: .topTrailing) {
                                    // Image
                                    if index < images.count {
                                        Image(uiImage: images[index])
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 150)
                                            .clipped()
                                            .cornerRadius(8)
                                            .opacity(isSelectionMode && selectedIndices.contains(index) ? 0.5 : 1.0)
                                            .onTapGesture {
                                                handleTap(at: index)
                                            }
                                    }
                                    
                                    // Selection Indicator
                                    if isSelectionMode {
                                        Image(systemName: selectedIndices.contains(index) ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedIndices.contains(index) ? .blue : .white)
                                            .padding(5)
                                            .background(Color.black.opacity(0.3))
                                            .clipShape(Circle())
                                            .padding(4)
                                    } else {
                                        // Page Number
                                        Text("\(index + 1)")
                                            .font(.caption2)
                                            .padding(4)
                                            .background(Color.black.opacity(0.6))
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                            .padding(4)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Page Manager")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if !isLoading {
                            if isSelectionMode {
                                Button(role: .destructive) {
                                    deleteSelectedPages()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(selectedIndices.isEmpty)
                                
                                Button("Cancel") {
                                    isSelectionMode = false
                                    selectedIndices.removeAll()
                                }
                            } else {
                                Button("Select") {
                                    isSelectionMode = true
                                }
                            }
                        }
                    }
                }
            }
            .task {
                loadImages()
            }
        }
    }
    
    func loadImages() {
        Task {
            do {
                let extracted = try await conversionManager.extractImages(from: pdf.url) { progress in
                    Task { @MainActor in self.loadingProgress = progress }
                }
                await MainActor.run {
                    self.images = extracted
                    self.isLoading = false
                }
            } catch {
                print("Error loading pages: \(error)")
            }
        }
    }
    
    func handleTap(at index: Int) {
        if isSelectionMode {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
        } else {
            // ✅ Fix: Properly Open Panel Editor AND Handle Save
            let image = images[index]
            
            // 1. Run AI detection first so the user has something to edit
            Task {
                let panels = await PanelExtractor.detectPanels(in: image, mode: conversionManager.conversionSettings.epubSettings.panelDetectionMode)
                
                await MainActor.run {
                    let session = PanelEditSession(id: UUID(), originalImage: image, panels: panels)
                    
                    conversionManager.currentPanelSession = session
                    
                    // 2. Define what happens when they click "Save"
                    conversionManager.panelEditorCompletion = { resultSession in
                        if let result = resultSession {
                            print("User saved \(result.panels.count) panels for page \(index)")
                            // NOTE: In a full implementation, you would save 'result.panels'
                            // to a 'manifest.json' file here so the Converter uses it later.
                            // For now, this confirms the UI loop works.
                        }
                    }
                    
                    conversionManager.showingPanelEditor = true
                }
            }
        }
    }
    
    func deleteSelectedPages() {
        guard !selectedIndices.isEmpty else { return }
        isLoading = true
        
        Task {
            do {
                try await conversionManager.deletePages(from: pdf, pageIndices: selectedIndices)
                selectedIndices.removeAll()
                isSelectionMode = false
                loadImages()
            } catch {
                print("Delete failed: \(error)")
                isLoading = false
            }
        }
    }
}
