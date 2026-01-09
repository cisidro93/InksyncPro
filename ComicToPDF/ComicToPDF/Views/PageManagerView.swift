import SwiftUI

class ImageLoaderModel: ObservableObject {
    @Published var image: UIImage?
    private var currentOperation: Operation?
    
    // Global Static Queue: Only 1 image loads at a time across the ENTIRE app.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1 // STRICT SERIAL LOADING
        q.qualityOfService = .userInteractive
        return q
    }()
    
    func load(url: URL) {
        // Cancel any previous load for this cell
        currentOperation?.cancel()
        
        let operation = BlockOperation { [weak self] in
            // 1. Check Cancellation
            if self?.currentOperation?.isCancelled == true { return }
            
            // 2. Load Safely
            let downsampled = autoreleasepool {
                return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 150)
            }
            
            // 3. Update UI
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
    
    @State private var pageURLs: [URL] = []
    @State private var tempSessionDir: URL?
    
    @State private var selectedPages: Set<Int> = []
    @State private var isLoading = true
    @State private var pageToEdit: Int?
    
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Opening Book...")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    ZStack(alignment: .topTrailing) {
                                        // ✅ Robust OperationQueue Cell
                                        QueueThumbnailCell(url: pageURLs[index])
                                            .frame(height: 150)
                                            .cornerRadius(8)
                                        
                                        SelectionOverlay(
                                            isSelected: selectedPages.contains(index),
                                            hasManualEdits: conversionManager.panelOverrides[pdf.id]?[index] != nil
                                        )
                                    }
                                    .contentShape(Rectangle())
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
                                        .font(.caption2)
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
                await loadPages()
            }
            .onDisappear {
                cleanupTempFiles()
            }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    func loadPages() async {
        // Just extract URLs. Fast and safe.
        cleanupTempFiles()
        isLoading = true
        do {
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            self.pageURLs = result.files
            self.isLoading = false
        } catch {
            print("Error loading pages: \(error)")
        }
    }
    
    func cleanupTempFiles() {
        if let dir = tempSessionDir {
            try? FileManager.default.removeItem(at: dir)
            tempSessionDir = nil
        }
        pageURLs.removeAll()
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        isLoading = true
        do {
            try await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
            selectedPages.removeAll()
            await loadPages()
        } catch { print("Delete failed: \(error)") }
        isLoading = false
    }
}

// MARK: - Components

struct SelectionOverlay: View {
    let isSelected: Bool
    let hasManualEdits: Bool
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 3 : 1)
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .background(Circle().fill(.white))
                    .padding(4)
            }
            
            if hasManualEdits {
                Image(systemName: "scissors")
                    .font(.caption)
                    .padding(4)
                    .background(Color.yellow)
                    .clipShape(Circle())
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// ✅ The Robust Cell
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
                    ProgressView()
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
