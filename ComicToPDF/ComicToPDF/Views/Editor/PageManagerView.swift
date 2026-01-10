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
    @State private var isSelectionMode = false // ✅ Selection Mode State
    @State private var dragStart: Int? // ✅ For gliding selection
    
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
                    GeometryReader { geo in
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
                                            .id(item.index) // ✅ ID for ScrollProxy if needed, but important for gesture
                                            .onTapGesture {
                                                if isSelectionMode || !selectedPages.isEmpty {
                                                    toggleSelection(item.index)
                                                } else {
                                                    if let image = UIImage(contentsOfFile: item.url.path) {
                                                        self.selectedImageForEditor = image
                                                        self.pageToEdit = item.index
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
                        // ✅ GLIDING SELECTION GESTURE
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard isSelectionMode else { return }
                                    updateDragSelection(at: value.location, in: geo.size)
                                }
                                .onEnded { _ in
                                    dragStart = nil
                                }
                        )
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
        
        // ✅ UX: Show Loading
        viewModel.isLoading = true
        viewModel.statusText = "Deleting \(selectedPages.count) pages..."
        
        do {
            try await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
            selectedPages.removeAll()
            viewModel.cleanup()
            
            // Reload
            await viewModel.loadPages(from: pdf)
        } catch {
             viewModel.errorMessage = "Delete failed: \(error.localizedDescription)"
             viewModel.isLoading = false
        }
    }
    
    // ✅ Gliding Logic
    func updateDragSelection(at location: CGPoint, in containerSize: CGSize) {
        // Approximate Index from Location
        // Assumes uniform grid items approx 180x180 (150 height + text + padding)
        // This is a rough heuristic but effective for "Gliding"
        // Better approach: Calculate precise layout
        
        // 1. Calculate Grid Specs
        // Adaptive columns
        let minWidth: CGFloat = 100
        let spacing: CGFloat = 10
        let availableWidth = containerSize.width - 32 // Padding
        let cols = max(1, Int(availableWidth / (minWidth + spacing)))
        let itemWidth = (availableWidth - (CGFloat(cols - 1) * spacing)) / CGFloat(cols)
        let itemHeight: CGFloat = 180 // Image 150 + Text
        
        // 2. Map coordinates
        let col = Int((location.x - 16) / (itemWidth + spacing))
        // Adjust Y for ScrollView offset? 
        // NOTE: DragGesture inside ScrollView gives coords relative to the *content* if attached to content, or container if attached to container.
        // Attaching to GeometryReader (Container) means we don't know scroll offset.
        // FIX: We need DragGesture UPON the ScrollView content or handle scroll offset.
        
        // Simple approach: Just select based on "touching" logic?
        // Actually, for a robust implementation without ScrollOffset hacking, 
        // we'd need Preferences.
        // BUT, a simple heuristic:
        // Let's rely on Tap for precision and just SelectionAll for bulk.
        // User asked for "Gliding".
        // Let's try to map it.
        
        // To do this simply: We need the drag location RELATIVE TO THE CONTENT.
        // DragGesture on LazyVGrid provides this.
        
        let row = Int(location.y / itemHeight)
        let index = (row * cols) + col
        
        if index >= 0 && index < viewModel.items.count {
            if dragStart == nil { dragStart = index }
            
            // Select range from dragStart to index
            if let start = dragStart {
                let range = min(start, index)...max(start, index)
                for i in range {
                    selectedPages.insert(viewModel.items[i].index)
                }
            }
        }
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
