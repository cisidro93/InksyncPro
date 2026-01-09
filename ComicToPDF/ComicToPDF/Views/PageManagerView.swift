import SwiftUI

// Safe Model for Grid Items
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
    @State private var pageItems: [GridPageItem] = []
    @State private var tempSessionDir: URL?
    @State private var isLoading = true
    @State private var debugMessage: String?
    
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
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
                        Text("Extracting...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.top, 10)
                    }
                } else {
                    // ✅ LIST VIEW (Most Stable Layout)
                    List(pageItems) { item in
                        HStack {
                            SimpleAsyncCell(url: item.url)
                                .frame(width: 60, height: 90)
                                .cornerRadius(4)
                            
                            Text("Page \(item.index + 1)")
                                .font(.headline)
                            
                            Spacer()
                            
                            // Guided View Indicator
                            if conversionManager.panelOverrides[pdf.id]?[item.index] != nil {
                                Image(systemName: "scissors")
                                    .foregroundColor(.orange)
                            }
                            
                            // Checkmark
                            if selectedPages.contains(item.index) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedPages.isEmpty {
                                pageToEdit = item.index
                            } else {
                                toggleSelection(item.index)
                            }
                        }
                    }
                    .listStyle(.plain)
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
        
        // 1. Brief pause
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        do {
            // Unzip using the new ROBUST MANUAL method
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            
            // 2. Map
            let items = result.files.enumerated().map { index, url in
                GridPageItem(url: url, index: index)
            }
            
            // 3. Update UI
            self.pageItems = items
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

// Simple Cell
struct SimpleAsyncCell: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Color.gray.opacity(0.1)
            }
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
