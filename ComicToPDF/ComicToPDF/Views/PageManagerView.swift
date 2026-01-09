import SwiftUI

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
                    // ERROR SCREEN
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.red)
                        Text("Cannot Open File")
                            .font(.title2)
                            .bold()
                        Text(debug)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                } else if isLoading {
                    // LOADING SCREEN
                    VStack(spacing: 15) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Extracting Pages...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Checking file integrity...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                } else {
                    // SAFE LIST VIEW
                    List(pageItems) { item in
                        HStack {
                            SimpleAsyncCell(url: item.url)
                                .frame(width: 60, height: 90)
                                .cornerRadius(4)
                            
                            Text("Page \(item.index + 1)")
                                .font(.headline)
                            
                            Spacer()
                            
                            if conversionManager.panelOverrides[pdf.id]?[item.index] != nil {
                                Image(systemName: "scissors")
                                    .foregroundColor(.orange)
                            }
                            
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
        
        // 1. Pause for UI stability
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        do {
            // 2. Extract
            let result = try await conversionManager.extractImageFiles(from: pdf.url)
            self.tempSessionDir = result.workingDir
            
            // 3. Map
            let items = result.files.enumerated().map { index, url in
                GridPageItem(url: url, index: index)
            }
            
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
        // Simple delete logic
    }
}

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
