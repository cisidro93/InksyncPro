import SwiftUI

// Safe Model
struct GridPageItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let index: Int
}

// ViewModel (Kept the isolated safe version)
@MainActor
class PageEditorViewModel: ObservableObject {
    @Published var items: [GridPageItem] = []
    @Published var isLoading = true
    @Published var statusText = "Preparing..."
    @Published var errorMessage: String?
    
    private var tempDir: URL?
    
    func loadPages(from pdf: ConvertedPDF) async {
        self.isLoading = true
        self.errorMessage = nil
        self.statusText = "Initializing..."
        
        // Safety Pause
        try? await Task.sleep(nanoseconds: 600_000_000)
        
        self.statusText = "Unpacking..."
        
        do {
            // Use ZipUtilities (Ensure ZipUtilities.swift is in your project)
            let (dir, urls) = try await ZipUtilities.extractComic(from: pdf.url)
            
            self.tempDir = dir
            self.items = urls.enumerated().map { index, url in
                GridPageItem(url: url, index: index)
            }
            self.isLoading = false
            
        } catch {
            print("Editor Error: \(error)")
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
    
    func cleanup() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
        items.removeAll()
    }
}

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    @StateObject private var viewModel = PageEditorViewModel()
    @State private var selectedPages: Set<Int> = []
    @State private var pageToEdit: Int?
    
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
    
    var body: some View {
        // ✅ CRITICAL FIX: Removed NavigationView wrapper.
        // This prevents the "Nested Navigation Crash".
        VStack(spacing: 0) {
            
            // Custom Header
            HStack {
                Text("Edit Pages")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    viewModel.cleanup()
                    dismiss()
                }
                .font(.body.bold())
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .shadow(color: Color.black.opacity(0.1), radius: 3, y: 1)
            .zIndex(1)
            
            // Main Content
            ZStack {
                if let error = viewModel.errorMessage {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Error Opening File")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                } else if viewModel.isLoading {
                    VStack(spacing: 15) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(viewModel.statusText)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(viewModel.items) { item in
                                VStack {
                                    SafeGridCell(url: item.url)
                                        .frame(height: 150)
                                        .cornerRadius(8)
                                        .overlay(
                                            ZStack(alignment: .topTrailing) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedPages.contains(item.index) ? Color.blue : Color.clear, lineWidth: 3)
                                                
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
                                    
                                    Text("\(item.index + 1)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .padding(.bottom, 80) // Space for bottom bar
                    }
                }
            }
            
            // Bottom Action Bar
            if !selectedPages.isEmpty {
                VStack {
                    Divider()
                    Button(role: .destructive) {
                        Task { await deleteSelected() }
                    } label: {
                        Text("Delete \(selectedPages.count) Pages")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                    .padding()
                }
                .background(Color(UIColor.systemBackground))
            }
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadPages(from: pdf)
            }
        }
        .sheet(item: $pageToEdit) { index in
            PanelEditorView(pdf: pdf, pageIndex: index)
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        try? await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
        selectedPages.removeAll()
        viewModel.cleanup()
        await viewModel.loadPages(from: pdf)
    }
}

// Safe Cell
struct SafeGridCell: View {
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
