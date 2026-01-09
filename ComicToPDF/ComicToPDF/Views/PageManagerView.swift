import SwiftUI

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // State
    @State private var pageURLs: [URL] = []
    @State private var tempSessionDir: URL?
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    // Standard Grid
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error Loading Pages")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                } else if isLoading {
                    ProgressView("Loading...")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    // Robust Image Loader
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
                                            
                                            // Indicator for Guided View
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
                                            toggleSelection(index)
                                        }
                                    }
                                    .onLongPressGesture {
                                        toggleSelection(index)
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
                    }
                }
            }
            .task {
                await loadPagesWithDelay()
            }
            .onDisappear {
                cleanupTempFiles()
            }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    // ✅ SAFETY DELAY: Fixes the startup crash
    func loadPagesWithDelay() async {
        isLoading = true
        errorMessage = nil
        
        // 1. Wait for view to appear
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        // 2. Start Work
        do {
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
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
        await loadPagesWithDelay()
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
