import SwiftUI

// ✅ THE FIX: A strict queue that forces images to load one-by-one.
// This prevents memory spikes even if you scroll fast.
class ImageLoaderModel: ObservableObject {
    @Published var image: UIImage?
    private var currentOperation: Operation?
    
    // Global Traffic Cop: Only 1 image decoding at a time app-wide.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    
    func load(url: URL) {
        // Stop any previous work for this cell
        currentOperation?.cancel()
        
        let operation = BlockOperation { [weak self] in
            // 1. Check if cancelled before starting heavy work
            if self?.currentOperation?.isCancelled == true { return }
            
            // 2. Safe Downsampling (Reads only header, creates tiny thumbnail)
            // Does NOT load full image into RAM.
            let downsampled = autoreleasepool {
                return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 150)
            }
            
            // 3. Update UI on Main Thread
            if self?.currentOperation?.isCancelled == true { return }
            DispatchQueue.main.async {
                self?.image = downsampled
            }
        }
        
        currentOperation = operation
        ImageLoaderModel.queue.addOperation(operation)
    }
    
    func cancel() {
        currentOperation?.cancel()
        image = nil
    }
}

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
    
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                if let error = errorMessage {
                    VStack(spacing: 15) {
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
                    VStack(spacing: 15) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Opening Book...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    // ✅ CRASH-PROOF CELL
                                    QueueThumbnailCell(url: pageURLs[index])
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
                await loadPagesSafe()
            }
            .onDisappear {
                cleanupTempFiles()
            }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    func loadPagesSafe() async {
        isLoading = true
        errorMessage = nil
        
        // 1. Safety Delay (Let the screen finish sliding up)
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // 2. Unzip Only (No image loading yet)
        do {
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            self.isLoading = false
        } catch {
            print("Error: \(error)")
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
    
    func cleanupTempFiles() {
        if let dir = tempSessionDir {
            try? FileManager.default.removeItem(at: dir)
            tempSessionDir = nil
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        isLoading = true
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        await loadPagesSafe()
    }
}

// ✅ THE SAFE COMPONENT
struct QueueThumbnailCell: View {
    let url: URL
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
                    // Only show spinner if it takes a moment
                    ProgressView()
                        .scaleEffect(0.8)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear {
            loader.load(url: url)
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
