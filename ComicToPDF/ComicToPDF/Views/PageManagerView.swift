import SwiftUI

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    @State private var thumbURLs: [URL] = []
    @State private var tempSessionDir: URL?
    @State private var loadingProgress: Double = 0.0
    
    @State private var selectedPages: Set<Int> = []
    @State private var isLoading = true
    @State private var pageToEdit: Int?
    
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    VStack(spacing: 15) {
                        ProgressView(value: loadingProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                        Text("Optimizing Pages...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(0..<thumbURLs.count, id: \.self) { index in
                                VStack {
                                    ZStack(alignment: .topTrailing) {
                                        // ✅ LOAD SAFE THUMBNAIL (Direct from Disk)
                                        SafeThumbnailCell(url: thumbURLs[index])
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
            .task { await loadPages() }
            .onDisappear { cleanupTempFiles() }
            .sheet(item: $pageToEdit) { index in
                PanelEditorView(pdf: pdf, pageIndex: index)
            }
        }
    }
    
    func loadPages() async {
        cleanupTempFiles()
        isLoading = true
        loadingProgress = 0.0
        
        do {
            // ✅ BATCH GENERATION: Prevents scrolling crash by doing heavy lifting upfront
            let session = try await conversionManager.preparePageSession(for: pdf) { progress in
                self.loadingProgress = progress
            }
            self.tempSessionDir = session.baseDir
            self.thumbURLs = session.thumbnails
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
        thumbURLs.removeAll()
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

struct SafeThumbnailCell: View {
    let url: URL
    
    var body: some View {
        // Since we pre-generated these to be tiny (5KB), we can load them using AsyncImage safely
        // No downsampling needed at runtime!
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                Color.red.opacity(0.3)
            case .empty:
                Color.gray.opacity(0.1)
            @unknown default:
                EmptyView()
            }
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
