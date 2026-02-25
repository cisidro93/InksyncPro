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
    
    // ✅ Reorder Logic
    func moveItem(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }
    
    // ✅ Save Reorder
    func saveReorder() async {
        guard !hasLoaded else { return } // Safety
        
        // Map current array order to original indices
        let newOrder = items.map { $0.index }
        
        // Verify if order changed
        let isChanged = newOrder.enumerated().contains { $0 != $1 }
        guard isChanged else { return }
        
        isLoading = true
        statusText = "Saving Order..."
        
        // We need to access ConversionManager from here... but it's not in ViewModel.
        // The View handles the call. We just need to expose the order?
        // Actually, ViewModel doesn't have access to ConversionManager.
        // We should add a 'saveAction' closure to ViewModel or handle in View.
        // Since logic is in View's Done button, we'll implement 'reorderPages' call there.
        // But we need to update ViewModel state to 'loading'.
    }
}

// ✅ Drop Delegate for Reordering


struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    @StateObject private var viewModel = PageEditorViewModel()
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    @State private var selectedImageForEditor: UIImage?
    @State private var isSelectionMode = false // ✅ Selection Mode State
    @State private var dragStart: Int?

    @State private var draggedItem: GridPageItem? // ✅ Drag for Reordering
    @State private var showingMetadataEditor = false
    @State private var showingTrimSheet = false
    @State private var extractedText: String = ""
    @State private var showingTextResult = false
    @State private var showingChapters = false // ✅ NEW
    
    // ✅ Live PDF Reference (Replaces local copy to reflect updates)
    var livePDF: ConvertedPDF {
        conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf
    }

    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                                    PageManagerGridItem(
                                        item: item,
                                        pdf: pdf,
                                        isSelectionMode: isSelectionMode,
                                        isSelected: selectedPages.contains(item.index),
                                        items: $viewModel.items,
                                        draggedItem: $draggedItem,
                                        onToggleSelection: { toggleSelection(item.index) },
                                        onEdit: { image in
                                            self.selectedImageForEditor = image
                                            self.pageToEdit = item.index
                                        }
                                    )
                                }
                            }
                            .padding()
                            .padding(.bottom, 80)
                            // ✅ GLIDING SELECTION GESTURE (Conditional)
                            // Only attach drag gesture when isSelectionMode is TRUE
                            // This is a rough heuristic but effective for "Gliding"
                            // Better approach: Calculate precise layout
                            .gesture(
                                isSelectionMode ?
                                DragGesture()
                                    .onChanged { value in
                                        updateDragSelection(at: value.location, in: geo.size)
                                    }
                                    .onEnded { _ in
                                        dragStart = nil
                                    }
                                : nil
                            )
                        }
                    }
                }
            }
            
            // Bottom Action Bar
            if !selectedPages.isEmpty {
                VStack {
                    Divider()
                    HStack(spacing: 16) {
                        // Only show Split/Trim for Comics
                        if pdf.contentType != .book {
                            // Split/Extract Button
                            Button {
                                Task { await splitSelected() }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up.on.square")
                                        .font(.title2)
                                    Text("New Comic")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                            }
                            
                            // Trim Button
                            Button {
                                showingTrimSheet = true
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "scissors")
                                        .font(.title2)
                                    Text("Trim")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange.opacity(0.1))
                                .foregroundColor(.orange)
                                .cornerRadius(8)
                            }
                        } else {
                            // ✅ Book Specific: Extract Text
                             if selectedPages.count == 1 {
                                 Button {
                                     Task { await extractTextFromSelected() }
                                 } label: {
                                     VStack(spacing: 4) {
                                         Image(systemName: "text.viewfinder")
                                             .font(.title2)
                                         Text("OCR")
                                             .font(.caption)
                                     }
                                     .frame(maxWidth: .infinity)
                                     .padding()
                                     .background(Color.purple.opacity(0.1))
                                     .foregroundColor(.purple)
                                     .cornerRadius(8)
                                 }
                             }
                        }
                        
                        // Delete Button
                        Button(role: .destructive) {
                            Task { await deleteSelected() }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.title2)
                                    .padding(.bottom, 2)
                                Text("Delete")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
                .background(Color(UIColor.systemBackground))
            }
        }
        .navigationTitle("Editor Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") {
                    Task {
                        if !selectedPages.isEmpty && !isSelectionMode {
                            await saveReorder()
                        }
                        viewModel.cleanup()
                        dismiss()
                    }
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if livePDF.contentType == .book {
                        Menu {
                            Button(action: { Task { await scanChapters() } }) {
                                Label("Scan for Chapters", systemImage: "doc.text.magnifyingglass")
                            }
                            
                            if !livePDF.chapters.isEmpty {
                                Button(action: { showingChapters = true }) {
                                    Label("View Chapters (\(livePDF.chapters.count))", systemImage: "list.bullet")
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                    }
                    
                    Button(action: { showingMetadataEditor = true }) {
                        Image(systemName: "info.circle")
                    }
                    
                    Button(action: { isSelectionMode.toggle() }) {
                        Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    
                    Menu {
                        Button(action: { selectFirst(20) }) { Label("Select First 20", systemImage: "number.square") }
                        Button(action: { selectFirst(50) }) { Label("Select First 50", systemImage: "number.square") }
                        Button(action: { selectFirst(100) }) { Label("Select First 100", systemImage: "number.square") }
                        Button(action: { selectAll() }) { Label("Select All", systemImage: "checkmark.circle.fill") }
                        Button(role: .destructive, action: { selectedPages.removeAll() }) { Label("Deselect All", systemImage: "xmark.circle") }
                    } label: {
                        Image(systemName: "checklist")
                    }
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { pageToEdit != nil },
            set: { if !$0 { pageToEdit = nil } }
        )) {
            if let index = pageToEdit {
                editorView(for: index)
            }
        }
        .task {
            // Trigger load once
            await viewModel.loadPages(from: pdf)
        }
        .sheet(isPresented: $showingChapters) {
             NavigationView {
                 List {
                     if livePDF.chapters.isEmpty {
                         Text("No chapters detected.")
                             .foregroundColor(.secondary)
                     } else {
                         ForEach(livePDF.chapters) { chapter in
                             Button(action: {
                                 // Close sheet first
                                 showingChapters = false
                             }) {
                                 HStack {
                                     Text(chapter.title)
                                         .font(.headline)
                                     Spacer()
                                     Text("Page \(chapter.pageIndex + 1)")
                                         .font(.caption)
                                         .foregroundColor(.secondary)
                                 }
                             }
                         }
                     }
                 }
                 .navigationTitle("Chapters")
                 .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showingChapters = false } } }
             }
        }
        .sheet(isPresented: $showingTextResult) {
            NavigationView {
                ScrollView {
                    Text(extractedText)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Extracted Text")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showingTextResult = false }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            UIPasteboard.general.string = extractedText
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        }
        } // End NavigationStack
    }
    
    // ✅ Helper to avoid duplicating the view code
    @ViewBuilder
    func editorView(for index: Int) -> some View {
        PrecisionCanvasView(
            pdf: pdf,
            pageIndex: index,
            conversionManager: conversionManager
        )
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
    
    func extractTextFromSelected() async {
        guard let index = selectedPages.first, let item = viewModel.items.first(where: { $0.index == index }) else { return }
        
        viewModel.isLoading = true
        viewModel.statusText = "Scanning Text..."
        
        do {
            if let image = UIImage(contentsOfFile: item.url.path) {
                let text = try await OCREngine.shared.recognizeText(from: image, languages: [conversionManager.conversionSettings.ocrLanguage.rawValue])
                extractedText = text
                showingTextResult = true
            }
            viewModel.isLoading = false
        } catch {
            viewModel.errorMessage = "OCR Failed: \(error.localizedDescription)"
            viewModel.isLoading = false
        }
    }
    
    func splitSelected() async {
        guard !selectedPages.isEmpty else { return }
        viewModel.isLoading = true
        viewModel.statusText = "Extracting \(selectedPages.count) pages..."
        
        do {
            // Convert Set to Sorted Array to keep page order
            let sortedIndices = selectedPages.sorted()
            let _ = try await conversionManager.extractPages(from: pdf, pageIndices: sortedIndices, asImages: true)
            
            viewModel.statusText = "Created New Comic!"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            selectedPages.removeAll()
            viewModel.isLoading = false
        } catch {
            viewModel.errorMessage = "Split failed: \(error.localizedDescription)"
            viewModel.isLoading = false
        }
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
    
    // ✅ Actual Save Logic using ConversionManager
    func saveReorder() async {
        // 1. Get New Order (Indices)
        // We map the CURRENT array order to the ORIGINAL indices.
        // e.g. [Item(index: 5), Item(index: 0)] -> [5, 0]
        let newOrder = viewModel.items.map { $0.index }
        
        // Check if actually changed (compare to sorted 0..n)
        let originalOrder = Array(0..<viewModel.items.count)
        guard newOrder != originalOrder else { return }
        
        do {
            viewModel.isLoading = true
            viewModel.statusText = "Saving New Order..."
            
            // This replaces the file on disk.
            let newURL = try await conversionManager.reorderPages(pdf, newOrder: newOrder)
            print("Reorder Saved to: \(newURL.lastPathComponent)")
            
        } catch {
            print("Reorder Failed: \(error)")
            viewModel.errorMessage = "Failed to save order: \(error.localizedDescription)"
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
    // ✅ Chapter Scanning
    func scanChapters() async {
        viewModel.isLoading = true
        await conversionManager.detectChapters(for: pdf)
        viewModel.isLoading = false
        
        // Refresh
        await viewModel.loadPages(from: pdf)
        
        if !livePDF.chapters.isEmpty {
            showingChapters = true
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
