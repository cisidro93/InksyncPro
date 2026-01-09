import SwiftUI

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // Switch to URL-based storage for OOM safety
    @State private var pageURLs: [URL] = []
    @State private var tempSessionDir: URL?
    
    @State private var selectedPages: Set<Int> = []
    @State private var isLoading = true
    @State private var pageToEdit: Int?
    
    // Optimized Grid: Fewer columns to reduce concurrent memory load
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    VStack {
                        ProgressView()
                        Text("Unpacking Pages...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }
                } else {
                    ScrollView {
                        // LazyGrid ensures we only load what's on screen
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    // ✅ OPTIMIZED CELL
                                    ZStack(alignment: .topTrailing) {
                                        // 1. The Heavy Image (Isolated)
                                        PageThumbnailCell(url: pageURLs[index])
                                            .frame(height: 150)
                                            .cornerRadius(8)
                                        
                                        // 2. The Selection Overlay (Lightweight)
                                        // This redraws instantly without forcing the image to reload
                                        SelectionOverlay(
                                            isSelected: selectedPages.contains(index),
                                            hasManualEdits: conversionManager.panelOverrides[pdf.id]?[index] != nil
                                        )
                                    }
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
        cleanupTempFiles()
        isLoading = true
        do {
            // Unzip to temp directory and get URLs
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
            await loadPages() // Reload from new file
        } catch { print("Delete failed: \(error)") }
        isLoading = false
    }
}

// MARK: - Optimized Components

// 1. Lightweight Selection Overlay (Redraws Cheaply)
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

// 2. Heavy Image Cell (Memory Managed)
struct PageThumbnailCell: View, Equatable {
    let url: URL
    @State private var image: UIImage?
    
    // Conforming to Equatable ensures this view DOES NOT redraw when parent state (selection) changes
    static func == (lhs: PageThumbnailCell, rhs: PageThumbnailCell) -> Bool {
        return lhs.url == rhs.url
    }
    
    var body: some View {
        GeometryReader { geo in
            if let img = image {
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
                .task(priority: .medium) {
                    await loadImage()
                }
            }
        }
        .onDisappear {
            // Aggressive Memory Cleanup
            self.image = nil
        }
    }
    
    func loadImage() async {
        // Run in detached task to keep UI smooth
        let loadedImage = await Task.detached { () -> UIImage? in
            // Use Autoreleasepool to ensure temporary allocations are dumped immediately
            return autoreleasepool {
                return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 200)
            }
        }.value
        
        await MainActor.run {
            self.image = loadedImage
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
