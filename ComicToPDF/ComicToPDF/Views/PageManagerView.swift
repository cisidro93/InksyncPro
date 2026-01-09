import SwiftUI

// ✅ RENAMED: 'GridPageItem' avoids conflict with your existing 'PageItem'
struct GridPageItem: Identifiable {
    let id = UUID()
    let url: URL
    let index: Int
}

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    // State
    @State private var gridItems: [GridPageItem] = [] // Renamed state
    @State private var tempSessionDir: URL?
    @State private var isLoading = true
    @State private var debugMessage: String?
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    // Standard Grid
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        NavigationView {
            VStack {
                if let debug = debugMessage {
                    // Error State
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Stopped")
                            .font(.headline)
                        Text(debug)
                            .font(.caption)
                            .padding()
                    }
                } else if isLoading {
                    // Loading State
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Reading Pages...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.top, 10)
                    }
                } else {
                    // Grid State
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(gridItems) { item in
                                VStack {
                                    // ✅ SAFE CELL (No GeometryReader)
                                    SimpleAsyncCell(url: item.url)
                                        .frame(height: 150) // Fixed height is critical for stability
                                        .cornerRadius(8)
                                        .overlay(
                                            ZStack(alignment: .topTrailing) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedPages.contains(item.index) ? Color.blue : Color.clear, lineWidth: 3)
                                                
                                                // Guided View Indicator
                                                if conversionManager.panelOverrides[pdf.id]?[item.index] != nil {
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
                                                pageToEdit = item.index
                                            } else {
                                                toggleSelection(item.index)
                                            }
                                        }
                                        .onLongPressGesture {
                                            toggleSelection(item.index)
                                        }
                                    
                                    Text("\(item.index + 1)")
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
        debugMessage = nil
        
        // 1. Brief pause to let transition finish
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        do {
            print("--- STARTING UNZIP ---")
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            
            print("--- FILES FOUND: \(result.files.count) ---")
            
            // 2. Map to Structs
            let items = result.files.enumerated().map { index, url in
                GridPageItem(url: url, index: index)
            }
            
            // 3. Update UI
            self.gridItems = items
            self.isLoading = false
            
        } catch {
            print("--- ERROR: \(error) ---")
            self.debugMessage = error.localizedDescription
            self.isLoading = false
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
        isLoading = true
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        await loadPagesSafe()
    }
}

// ✅ ULTRA-SIMPLE CELL
// Uses native AsyncImage. No GeometryReader. No custom queuing.
struct SimpleAsyncCell: View {
    let url: URL
    
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ZStack {
                    Color.gray.opacity(0.1)
                    ProgressView()
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                ZStack {
                    Color.gray.opacity(0.1)
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                }
            @unknown default:
                EmptyView()
            }
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
