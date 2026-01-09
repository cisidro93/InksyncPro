import SwiftUI

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // Simple State
    @State private var pageURLs: [URL] = []
    @State private var tempSessionDir: URL?
    @State private var isLoading = true
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    // Standard Grid
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Pages...")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    // Simple Image Cell using Standard AsyncImage
                                    AsyncImage(url: pageURLs[index]) { phase in
                                        if let image = phase.image {
                                            image
                                                .resizable()
                                                .scaledToFit()
                                        } else {
                                            Color.gray.opacity(0.1)
                                        }
                                    }
                                    .frame(height: 150)
                                    .cornerRadius(8)
                                    .overlay(
                                        ZStack(alignment: .topTrailing) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selectedPages.contains(index) ? Color.blue : Color.clear, lineWidth: 3)
                                            
                                            // Show indicator if manual panels exist
                                            if conversionManager.panelOverrides[pdf.id]?[index] != nil {
                                                Image(systemName: "scissors")
                                                    .font(.caption)
                                                    .padding(4)
                                                    .background(Color.yellow)
                                                    .clipShape(Circle())
                                                    .padding(4)
                                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                            }
                                        }
                                    )
                                    .onTapGesture {
                                        if selectedPages.isEmpty {
                                            pageToEdit = index
                                        } else {
                                            if selectedPages.contains(index) {
                                                selectedPages.remove(index)
                                            } else {
                                                selectedPages.insert(index)
                                            }
                                        }
                                    }
                                    .onLongPressGesture {
                                        if selectedPages.contains(index) {
                                            selectedPages.remove(index)
                                        } else {
                                            selectedPages.insert(index)
                                        }
                                    }
                                    
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Edit Pages")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    if !selectedPages.isEmpty {
                        Button(role: .destructive) {
                            Task { await deleteSelected() }
                        } label: {
                            Text("Delete \(selectedPages.count) Pages")
                        }
                    } else {
                         Text("Tap to edit • Long press to select")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .task {
                await loadPagesSimple()
            }
            .onDisappear {
                cleanupTempFiles()
            }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    // The "Old Reliable" Loading Logic
    func loadPagesSimple() async {
        isLoading = true
        do {
            // Just get the file URLs. No processing. No resizing.
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            self.isLoading = false
        } catch {
            print("Error: \(error)")
            self.isLoading = false
        }
    }
    
    func cleanupTempFiles() {
        if let dir = tempSessionDir {
            try? FileManager.default.removeItem(at: dir)
            tempSessionDir = nil
        }
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        isLoading = true
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        await loadPagesSimple()
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
