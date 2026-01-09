import SwiftUI

// ✅ GLOBAL SERIAL LOADER
// Prevents memory spikes by forcing images to load one at a time.
class ImageLoaderModel: ObservableObject {
    @Published var image: UIImage?
    private var currentOperation: Operation?
    
    // Static queue shared by all cells
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1 // Strict serial loading
        q.qualityOfService = .userInteractive
        return q
    }()
    
    func load(url: URL) {
        // Cancel previous request
        currentOperation?.cancel()
        
        let operation = BlockOperation { [weak self] in
            if self?.currentOperation?.isCancelled == true { return }
            
            // 🛑 Heavy Lifting: Downsample from disk
            // Uses autoreleasepool to ensure RAM is dumped instantly
            let downsampled = autoreleasepool {
                return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 200)
            }
            
            if self?.currentOperation?.isCancelled == true { return }
            
            // 🚀 Update UI
            DispatchQueue.main.async {
                self?.image = downsampled
            }
        }
        
        currentOperation = operation
        ImageLoaderModel.queue.addOperation(operation)
    }
    
    func cancel() {
        currentOperation?.cancel()
    }
}

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // View States
    enum ViewState {
        case loading
        case displaying
        case error(String)
    }
    
    @State private var viewState: ViewState = .loading
    @State private var pageURLs: [URL] = []
    @State private var tempSessionDir: URL?
    
    // Traffic Light System
    @State private var canLoadImages = false
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    // ✅ Fixed column size (Removes need for GeometryReader)
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                switch viewState {
                case .loading:
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Opening Book...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    
                case .error(let msg):
                    VStack(spacing: 15) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error")
                            .font(.headline)
                        Text(msg)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    
                case .displaying:
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    // ✅ FIXED CELL (No GeometryReader)
                                    QueueThumbnailCell(url: pageURLs[index], shouldLoad: canLoadImages)
                                        .frame(height: 150) // Fixed height prevents layout loops
                                        .cornerRadius(8)
                                        .overlay(
                                            ZStack(alignment: .topTrailing) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedPages.contains(index) ? Color.blue : Color.clear, lineWidth: 3)
                                                
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
                        // ✅ GPU Offloading (Helps main thread performance)
                        .drawingGroup()
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
                await loadContent()
            }
            .onDisappear {
                cleanupTempFiles()
            }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    // ✅ Safe Loading Sequence
    func loadContent() async {
        viewState = .loading
        canLoadImages = false
        
        // Wait for transition to finish
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        do {
            // Background unzip
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            
            // Show grid
            withAnimation {
                viewState = .displaying
            }
            
            // Start loading images slightly after grid appears
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.canLoadImages = true
            
        } catch {
            viewState = .error(error.localizedDescription)
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
        viewState = .loading
        canLoadImages = false
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        await loadContent()
    }
}

// ✅ SAFE CELL: No GeometryReader, strict loading
struct QueueThumbnailCell: View {
    let url: URL
    let shouldLoad: Bool
    @StateObject private var loader = ImageLoaderModel()
    
    var body: some View {
        ZStack {
            if let img = loader.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.gray.opacity(0.1)
                if shouldLoad {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .onChange(of: shouldLoad) { newValue in
            if newValue { loader.load(url: url) }
        }
        .onAppear {
            if shouldLoad { loader.load(url: url) }
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
