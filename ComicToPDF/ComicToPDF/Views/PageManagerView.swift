import SwiftUI
import ZIPFoundation

// ✅ 1. Safe Data Model
struct GridPageItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let index: Int
}

// ✅ 2. Isolated View Model (The Sandbox)
// This handles all the heavy lifting away from the View code.
@MainActor
class PageEditorViewModel: ObservableObject {
    @Published var items: [GridPageItem] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    
    private var tempDir: URL?
    
    func loadPages(from sourcePDF: ConvertedPDF) async {
        self.isLoading = true
        self.errorMessage = nil
        
        // Safety Pause: Let the UI transition finish completely
        try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
        
        // Run extraction on a background thread to keep UI responsive
        let extractionResult = await Task.detached(priority: .userInitiated) { () -> Result<(URL, [URL]), Error> in
            let fileManager = FileManager.default
            let uniqueID = UUID().uuidString
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("Editor_\(uniqueID)")
            
            do {
                // 1. Create Clean Temp Directory
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                // 2. Unzip (Standard robust unzip)
                try fileManager.unzipItem(at: sourcePDF.url, to: tempDir)
                
                // 3. Scan for Images
                let validExts = ["jpg", "jpeg", "png", "webp"]
                var foundURLs: [URL] = []
                
                if let subPaths = try? fileManager.subpathsOfDirectory(atPath: tempDir.path) {
                    let sortedPaths = subPaths.sorted()
                    for path in sortedPaths {
                        let ext = (path as NSString).pathExtension.lowercased()
                        // Strict filtering
                        if validExts.contains(ext) && !path.contains("__MACOSX") && !(path as NSString).lastPathComponent.hasPrefix(".") {
                            foundURLs.append(tempDir.appendingPathComponent(path))
                        }
                    }
                }
                
                return .success((tempDir, foundURLs))
            } catch {
                return .failure(error)
            }
        }.value
        
        // Handle Result back on Main Actor
        switch extractionResult {
        case .success(let (dir, urls)):
            self.tempDir = dir
            // Map to safe structs
            self.items = urls.enumerated().map { index, url in
                GridPageItem(url: url, index: index)
            }
            self.isLoading = false
            
        case .failure(let error):
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
    
    func cleanup() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
        items.removeAll()
    }
}

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // Use the Isolated View Model
    @StateObject private var viewModel = PageEditorViewModel()
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    // Reverting to Grid (List was just for testing, Grid is what you want)
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                if let error = viewModel.errorMessage {
                    // ERROR STATE
                    VStack(spacing: 15) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Could Not Load Pages")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .padding()
                    }
                } else if viewModel.isLoading {
                    // LOADING STATE
                    VStack(spacing: 15) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Opening Editor...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    // CONTENT STATE
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(viewModel.items) { item in
                                VStack {
                                    // Safe Async Cell
                                    SafeGridCell(url: item.url)
                                        .frame(height: 150)
                                        .cornerRadius(8)
                                        .overlay(
                                            ZStack(alignment: .topTrailing) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedPages.contains(item.index) ? Color.blue : Color.clear, lineWidth: 3)
                                                
                                                // Guided View Indicator
                                                if conversionManager.panelOverrides[pdf.id]?[item.index] != nil {
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
                                                pageToEdit = item.index
                                            } else {
                                                toggleSelection(item.index)
                                            }
                                        }
                                        .onLongPressGesture {
                                            toggleSelection(item.index)
                                        }
                                    
                                    Text("\(item.index + 1)")
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
                // Trigger load ONLY once
                if viewModel.items.isEmpty {
                    await viewModel.loadPages(from: pdf)
                }
            }
            .onDisappear {
                // Don't cleanup immediately on disappear (caused issues with sheet)
                // Cleanup happens when ViewModel is deallocated
            }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        // Simple passthrough to manager
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        
        // Reload via VM
        viewModel.cleanup()
        await viewModel.loadPages(from: pdf)
    }
}

// ✅ Safe Cell using native AsyncImage
struct SafeGridCell: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else if phase.error != nil {
                Color.red.opacity(0.2)
            } else {
                Color.gray.opacity(0.1)
            }
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
