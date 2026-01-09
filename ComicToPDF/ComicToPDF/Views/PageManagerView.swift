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
    
    let columns = [GridItem(.adaptive(minimum: 100))]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Processing Pages...")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 15) {
                            ForEach(0..<pageURLs.count, id: \.self) { index in
                                VStack {
                                    ZStack(alignment: .topTrailing) {
                                        // ✅ Lazy Load Image from Disk
                                        PageThumbnailCell(url: pageURLs[index])
                                            .frame(height: 150)
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedPages.contains(index) ? Color.blue : Color.gray.opacity(0.3), lineWidth: selectedPages.contains(index) ? 3 : 1)
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
                                        
                                        if selectedPages.contains(index) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                                .background(Circle().fill(.white))
                                                .padding(4)
                                        }
                                        
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
                                    Text("Page \(index + 1)")
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
                    } else {
                        Text("Tap a page to edit panels. Long press to select.")
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

// ✅ Efficient Lazy Loading Cell
struct PageThumbnailCell: View {
    let url: URL
    @State private var image: UIImage?
    
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
                    // Downsample on background thread
                    if let downsampled = ConversionManager.loadDownsampledImageStatic(at: url, maxDimension: 300) {
                        await MainActor.run { self.image = downsampled }
                    }
                }
            }
        }
        // ✅ CRITICAL: Dump memory immediately when scrolled off-screen
        .onDisappear {
            self.image = nil
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
