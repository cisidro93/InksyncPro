import SwiftUI

// ✅ STRICT SERIAL LOADER (Traffic Cop)
// Only allows 1 image to load at a time globally. Crash-proof.
actor SerialImageLoader {
    static let shared = SerialImageLoader()
    
    func load(url: URL) async -> UIImage? {
        // Yield ensures the UI main thread always has priority
        await Task.yield()
        
        return autoreleasepool {
            return ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 150)
        }
    }
}

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
    
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Processing Pages...")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    ZStack(alignment: .topTrailing) {
                                        // ✅ Serial Loading Cell
                                        SerialThumbnailCell(url: pageURLs[index])
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
        cleanupTempFiles()
        isLoading = true
        do {
            // Instant Unzip (No image processing)
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

// ✅ Safe Serial Cell
struct SerialThumbnailCell: View, Equatable {
    let url: URL
    @State private var image: UIImage?
    
    static func == (lhs: SerialThumbnailCell, rhs: SerialThumbnailCell) -> Bool {
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
                    ProgressView() // Shows "Loading..." while waiting for traffic cop
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .task {
                    // Ask traffic cop for image
                    if let loaded = await SerialImageLoader.shared.load(url: url) {
                        if !Task.isCancelled {
                            self.image = loaded
                        }
                    }
                }
            }
        }
        .onDisappear {
            self.image = nil
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
