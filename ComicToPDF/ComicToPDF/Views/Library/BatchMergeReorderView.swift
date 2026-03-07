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
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(conversionManager.statusMessage ?? "Processing...")
                            .font(.headline)
                        Text(conversionManager.processingStatus)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Header Form
                    Form {
                        Section(header: Text("Output Name")) {
                            TextField("Collection Name", text: $mergedName)
                        }
                        
                        Section(header: Text("Settings")) {
                            Toggle("Manga Mode (Right-to-Left)", isOn: $mangaMode)
                        }
                    }
                    .frame(height: 200) // Constrain form height
                    
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
                                    GridThumbnail(file: file)
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
    
    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .systemBackground))
                    .frame(height: 140)
                    .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 2)
                
                Image(systemName: "doc.text.image")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 50)
                    .foregroundColor(.blue)
            }
            
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32)
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
