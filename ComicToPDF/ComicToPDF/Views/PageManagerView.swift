import SwiftUI

// ✅ ROBUST IMAGE LOADER
// Uses a static serial queue to prevent memory spikes
class ImageLoaderModel: ObservableObject {
    @Published var image: UIImage?
    private var currentOperation: Operation?
    
    // Global Traffic Cop: Strict Serial Loading
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1 // Only 1 image processes at a time
        q.qualityOfService = .userInitiated
        return q
    }()
    
    func load(url: URL) {
        // Cancel any existing request for this cell
        currentOperation?.cancel()
        
        let operation = BlockOperation { [weak self] in
            if self?.currentOperation?.isCancelled == true { return }
            
            // 🛑 Heavy Lifting (Downsampling from disk)
            // Done inside autoreleasepool to dump RAM immediately
            let downsampled = autoreleasepool {
                return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 150)
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
        // Don't nil the image immediately to prevent flickering during scroll
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
    
    // 🚦 Traffic Light: Prevents images from loading during the slide-up animation
    @State private var canLoadImages = false
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
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
                    .transition(.opacity)
                    
                case .error(let msg):
                    VStack(spacing: 15) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Could Not Load Pages")
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
                                    // ✅ Smart Cell
                                    // Listens to 'canLoadImages' to avoid animation lag
                                    QueueThumbnailCell(url: pageURLs[index], shouldLoad: canLoadImages)
                                        .frame(height: 150)
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
    
    // ✅ The Safe Loading Sequence
    func loadContent() async {
        // Step 1: Show Loading State
        viewState = .loading
        canLoadImages = false
        
        // Step 2: Unzip file (Background)
        // Wait a tiny bit to let the view transition start smoothly
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        do {
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            
            // Step 3: Show Grid (But keep images paused)
            withAnimation {
                viewState = .displaying
            }
            
            // Step 4: Turn on Images (Green Light)
            // Wait 0.5s for the Grid to draw its layout frames first.
            try? await Task.sleep(nanoseconds: 500_000_000)
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

// ✅ THUMBNAIL CELL (Aware of Traffic Light)
struct QueueThumbnailCell: View {
    let url: URL
    let shouldLoad: Bool // <--- Controlled by Parent
    @StateObject private var loader = ImageLoaderModel()
    
    var body: some View {
        GeometryReader { geo in
            if let img = loader.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ZStack {
                    Color.gray.opacity(0.1)
                    if shouldLoad {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
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
