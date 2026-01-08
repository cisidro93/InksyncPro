import SwiftUI

struct PageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    let pdf: ConvertedPDF
    
    @State private var pages: [UIImage] = []
    @State private var selectedPages: Set<Int> = []
    @State private var isLoading = true
    @State private var pageToEdit: Int? // ✅ Track which page to edit
    
    let columns = [GridItem(.adaptive(minimum: 100))]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Pages...")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 15) {
                            ForEach(0..<pages.count, id: \.self) { index in
                                VStack {
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: pages[index])
                                            .resizable()
                                            .scaledToFit()
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
                            Task {
                                await deleteSelected()
                            }
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
            .sheet(item: $pageToEdit) { index in
                if index < pages.count {
                    PanelEditorView(pdf: pdf, pageIndex: index, pageImage: pages[index])
                }
            }
        }
    }
    
    func loadPages() async {
        do {
            self.pages = try await conversionManager.extractImages(from: pdf.url) { _ in }
            self.isLoading = false
        } catch {
            print("Error loading pages: \(error)")
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) {
            selectedPages.remove(index)
        } else {
            selectedPages.insert(index)
        }
    }
    
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        isLoading = true
        do {
            try await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
            selectedPages.removeAll()
            await loadPages()
        } catch {
            print("Delete failed: \(error)")
        }
        isLoading = false
    }
}

// ✅ FIX: Silence Swift 6 Warning
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
