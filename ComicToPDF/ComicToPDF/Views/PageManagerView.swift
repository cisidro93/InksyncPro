import SwiftUI

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // State
    @State private var thumbURLs: [URL] = []
    @State private var tempSessionDir: URL?
    @State private var loadingProgress: Double = 0.0
    @State private var isReady = false // ✅ Gatekeeper: Keeps Grid OFF until ready
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]
    
    var body: some View {
        NavigationView {
            VStack {
                if !isReady {
                    // Phase 1: Loading Screen (Safe Mode)
                    VStack(spacing: 20) {
                        ProgressView(value: loadingProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                        
                        Text("Preparing Pages...")
                            .font(.headline)
                        Text("Optimizing for crash-free editing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    // Phase 2: The Grid (Only loads when safe)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(0..<thumbURLs.count, id: \.self) { index in
                                VStack {
                                    ZStack(alignment: .topTrailing) {
                                        // Safe Local File Image
                                        AsyncImage(url: thumbURLs[index]) { phase in
                                            if let image = phase.image {
                                                image.resizable().scaledToFit()
                                            } else {
                                                Color.gray.opacity(0.1)
                                            }
                                        }
                                        .frame(height: 150)
                                        .cornerRadius(8)
                                        .contentShape(Rectangle())
                                        
                                        // Selection Overlay
                                        ZStack(alignment: .topTrailing) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selectedPages.contains(index) ? Color.blue : Color.gray.opacity(0.3), lineWidth: selectedPages.contains(index) ? 3 : 1)
                                            
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
                        if isReady {
                            Text("Tap to edit • Long press to select")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            // ✅ Only start work when view actually appears
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
        cleanupTempFiles()
        isReady = false
        loadingProgress = 0.0
        
        do {
            // Uses the Throttled Generator (Sleeps between pages)
            let session = try await conversionManager.generateThumbnailsSafe(for: pdf) { progress in
                self.loadingProgress = progress
            }
            self.tempSessionDir = session.baseDir
            self.thumbURLs = session.thumbnails
            
            // Switch to Grid ONLY after success
            withAnimation {
                self.isReady = true
            }
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
        isReady = false
        do {
            try await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
            selectedPages.removeAll()
            await loadPagesSafe()
        } catch { print("Delete failed: \(error)") }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
