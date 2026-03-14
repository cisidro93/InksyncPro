import SwiftUI

struct BatchMergeReorderView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    

    // Binding to parent state
    @Binding var selectedFiles: [ConvertedPDF]
    
    @State private var mergedName: String = "Merged Collection"
    @State private var mangaMode: Bool = false
    @State private var isProcessing = false
    @State private var draggedItem: ConvertedPDF?
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isProcessing {
                    ImmersiveConversionOverlay(
                        pdfName: mergedName,
                        customMessage: conversionManager.statusMessage ?? "Merging Files..."
                    )
                } else {
                    // Header Form
                    Form {
                        Section {
                            TextField("Collection Name", text: $mergedName)
                        } header: {
                            Text("Output Name")
                        }
                        
                        Section {
                            Toggle("Manga Mode (Right-to-Left)", isOn: $mangaMode)
                            
                            Picker("Target Device", selection: $conversionManager.conversionSettings.targetDeviceProfile) {
                                ForEach(TargetDeviceProfile.allCases) { device in
                                    Text(device.rawValue).tag(device)
                                }
                            }
                            .pickerStyle(.menu)
                            
                            Toggle("E-Ink High Contrast Filter", isOn: $conversionManager.conversionSettings.optimizeForDevice)
                            
                            Picker("Image Quality", selection: $conversionManager.conversionSettings.compressionQuality) {
                                Text(CompressionPreset.compact.rawValue).tag(CompressionPreset.compact)
                                Text(CompressionPreset.balanced.rawValue).tag(CompressionPreset.balanced)
                                Text(CompressionPreset.highQuality.rawValue).tag(CompressionPreset.highQuality)
                            }
                            
                            Picker("Smart File Splitting", selection: $conversionManager.conversionSettings.splitMode) {
                                ForEach(FileSizeSplitMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                        } header: {
                            Text("Settings")
                        }
                    }
                    .frame(height: 300) // Constrain form height
                    
                    Divider()
                    
                    // Visual Reordering Grid
                    VStack(alignment: .leading) {
                        Text("Order (Drag to Reorder)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal)
                            .padding(.top, 16)
                        
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(selectedFiles) { file in
                                    GridThumbnail(file: file, conversionManager: conversionManager)
                                        .onDrag {
                                            self.draggedItem = file
                                            return NSItemProvider(object: file.id.uuidString as NSString)
                                        }
                                        .onDrop(of: [.text], delegate: ReorderDropDelegate(item: file, items: $selectedFiles, draggedItem: $draggedItem))
                                }
                            }
                            .padding()
                        }
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    
                    // Bottom Button
                    VStack {
                        Text("This will convert all selected files to EPUB and merge them into a single file. Internal files will be deleted afterwards to save space.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button {
                            startMerge()
                        } label: {
                            Text("Convert & Merge")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                    }
                    .padding(.top, 16)
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .navigationTitle("Visual Merge Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isProcessing {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }
    
    private func startMerge() {
        guard !selectedFiles.isEmpty else { return }
        isProcessing = true
        
        Task {
            // Call the manager to do the work
            await conversionManager.convertAndMerge(sourceFiles: selectedFiles, outputName: mergedName, mangaMode: mangaMode)
            
            await MainActor.run {
                isProcessing = false
                dismiss()
            }
        }
    }
}

// MARK: - Components

struct GridThumbnail: View {
    let file: ConvertedPDF
    let conversionManager: ConversionManager
    
    @State private var coverImage: UIImage? = nil
    
    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .systemGroupedBackground))
                    .frame(height: 160)
                    .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
                
                if let uiImage = coverImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                        .foregroundColor(.gray.opacity(0.5))
                }
                
                // Visual numbered badge if we can access the index 
                // We'll leave index out for now since drag-and-drop order visually conveys it
            }
            
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32)
        }
        .task {
            if let img = await conversionManager.loadCoverThumbnail(for: file) {
                await MainActor.run { self.coverImage = img }
            }
        }
    }
}

// MARK: - Drag Delegate

struct ReorderDropDelegate: DropDelegate {
    let item: ConvertedPDF
    @Binding var items: [ConvertedPDF]
    @Binding var draggedItem: ConvertedPDF?
    
    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem,
              draggedItem.id != item.id,
              let from = items.firstIndex(where: { $0.id == draggedItem.id }),
              let to = items.firstIndex(where: { $0.id == item.id }) else { return }
        
        if items[to].id != draggedItem.id {
            withAnimation(.default) {
                items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }
}
