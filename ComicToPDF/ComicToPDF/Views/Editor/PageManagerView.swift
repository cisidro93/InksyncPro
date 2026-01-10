import SwiftUI

// Safe Model
struct GridPageItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let index: Int
}

// ViewModel
@MainActor
class PageEditorViewModel: ObservableObject {
    @Published var items: [GridPageItem] = []
    @Published var isLoading = true
    @Published var statusText = "Preparing..."
    @Published var errorMessage: String?
    
    private var tempDir: URL?
    private var hasLoaded = false // ✅ Prevents double-triggering
    
    func loadPages(from pdf: ConvertedPDF) async {
        guard !hasLoaded else { return } // Stop if already loaded
        
        self.isLoading = true
        self.errorMessage = nil
        self.statusText = "Initializing..."
        
        // Safety Pause (Prevents UI animation conflict)
        try? await Task.sleep(nanoseconds: 600_000_000)
        
        self.statusText = "Unpacking..."
        
        do {
            // Call Surgical Extraction
            // FIX: Run heavy unzipping on a detached background task
            let (dir, urls) = try await Task.detached(priority: .userInitiated) {
                return try await ZipUtilities.extractComic(from: pdf.url)
            }.value
            
            self.tempDir = dir
            self.items = urls.enumerated().map { index, url in
                GridPageItem(url: url, index: index)
            }
            
            self.hasLoaded = true
            self.isLoading = false
            
        } catch {
            print("Editor Error: \(error)")
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
        hasLoaded = false
    }
}

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    @StateObject private var viewModel = PageEditorViewModel()
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    @State private var selectedImageForEditor: UIImage?
    @State private var isSelectionMode = false // ✅ NEW: Selection Mode State
    
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        // Simple VStack (No Nested Navigation)
        VStack(spacing: 0) {
            
            // Custom Header
            HStack {
                Text("Edit Pages")
                    .font(.headline)
                Spacer()
                
                // ✅ Selection Menu
                Menu {
                    Button(action: { selectFirst(20) }) { Label("Select First 20", systemImage: "number.square") }
                    Button(action: { selectFirst(50) }) { Label("Select First 50", systemImage: "number.square") }
                    Button(action: { selectFirst(100) }) { Label("Select First 100", systemImage: "number.square") }
                    Button(action: { selectAll() }) { Label("Select All", systemImage: "checkmark.circle.fill") }
                    Button(role: .destructive, action: { selectedPages.removeAll() }) { Label("Deselect All", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "checklist")
                        .font(.body)
                        .padding(8)
                }
                
                // ✅ Toggle Selection Mode
                Button(action: { isSelectionMode.toggle() }) {
                    Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.body)
                        .padding(8)
                        .foregroundColor(isSelectionMode ? .blue : .primary)
                }
                
                Button("Done") {
                    viewModel.cleanup()
                    dismiss()
                }
                .font(.body.bold())
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .shadow(color: Color.black.opacity(0.1), radius: 3, y: 1)
            .zIndex(1)
            
            // Main Content
            ZStack {
                if let error = viewModel.errorMessage {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error Opening File")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                } else if viewModel.isLoading {
                    VStack(spacing: 15) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(viewModel.statusText)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(viewModel.items) { item in
                                VStack {
                                    SafeGridCell(url: item.url)
                                        .frame(height: 150)
                                        .cornerRadius(8)
                                        .overlay(
                                            ZStack(alignment: .topTrailing) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedPages.contains(item.index) ? Color.blue : Color.clear, lineWidth: 3)
                                                
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
                                            if isSelectionMode || !selectedPages.isEmpty {
                                                // ✅ Selection Mode: Always Select/Deselect
                                                toggleSelection(item.index)
                                            } else {
                                                // ✅ Normal Mode: Open Editor
                                                if let image = UIImage(contentsOfFile: item.url.path) {
                                                    print("✅ Loaded image for editor: \(item.url.lastPathComponent)")
                                                    self.selectedImageForEditor = image
                                                    self.pageToEdit = item.index
                                                } else {
                                                    print("❌ Failed to load image at: \(item.url.path)")
                                                }
                                            }
                                        }
                                    
                                    Text("\(item.index + 1)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .padding(.bottom, 80)
                    }
                }
            }
            
            // Bottom Action Bar
            if !selectedPages.isEmpty {
                VStack {
                    Divider()
                    Button(role: .destructive) {
                        Task { await deleteSelected() }
                    } label: {
                        Text("Delete \(selectedPages.count) Pages")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                    .padding()
                }
                .background(Color(UIColor.systemBackground))
            }
        }
        .task {
            // Trigger load once
            await viewModel.loadPages(from: pdf)
        }
        .sheet(item: $pageToEdit) { index in
            PanelEditorView(
                pdf: pdf,
                pageIndex: index,
                initialImage: selectedImageForEditor // ✅ Pass the loaded image
            )
            .environmentObject(conversionManager)
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
    }
    
    // ✅ Batch Selection Helpers
    func selectFirst(_ count: Int) {
        selectedPages.removeAll()
        let limit = min(count, viewModel.items.count)
        for i in 0..<limit {
            selectedPages.insert(viewModel.items[i].index)
        }
    }
    
    func selectAll() {
        selectedPages = Set(viewModel.items.map { $0.index })
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        viewModel.cleanup()
        await viewModel.loadPages(from: pdf)
    }
}

// Safe Cell
struct SafeGridCell: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Color.gray.opacity(0.1)
            }
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
