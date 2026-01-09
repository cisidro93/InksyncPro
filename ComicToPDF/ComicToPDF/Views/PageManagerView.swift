import SwiftUI

// ✅ LIGHTWEIGHT STATIC LOADER
// No ObservableObject overhead. Just a dumb function that uses a queue.
struct SerialLoader {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1 // Strict serial loading
        q.qualityOfService = .userInteractive
        return q
    }()
    
    static func load(url: URL, completion: @escaping (UIImage?) -> Void) -> Operation {
        let operation = BlockOperation {
            // 1. Safe Downsample from disk
            let image = autoreleasepool {
                return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 200)
            }
            
            // 2. Return to Main Thread
            if !Task.isCancelled {
                DispatchQueue.main.async {
                    completion(image)
                }
            }
        }
        queue.addOperation(operation)
        return operation
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
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    // Fixed columns (Safe Layout)
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
                                    // ✅ LIGHTWEIGHT CELL
                                    // No StateObject. No geometry calculations.
                                    SimpleThumbnailCell(url: pageURLs[index])
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
    
    // ✅ Main Actor Safe Loading
    @MainActor
    func loadContent() async {
        viewState = .loading
        
        // Brief pause to let transition finish
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        do {
            // Unzip in background
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            
            // Switch to grid
            withAnimation {
                viewState = .displaying
            }
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
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        await loadContent()
    }
}

// ✅ ULTRA-LIGHT CELL (No Objects, Just State)
struct SimpleThumbnailCell: View {
    let url: URL
    @State private var image: UIImage?
    @State private var currentOperation: Operation?
    
    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.gray.opacity(0.1)
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .onAppear {
            // Start loading when visible
            currentOperation = SerialLoader.load(url: url) { loadedImage in
                self.image = loadedImage
            }
        }
        .onDisappear {
            // Cancel immediately if scrolled away
            currentOperation?.cancel()
            currentOperation = nil
            image = nil // Dump memory
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
