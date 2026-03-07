import SwiftUI
import PDFKit

@MainActor
class PDFContentEditorViewModel: ObservableObject {
    @Published var pages: [PDFPageItem] = []
    @Published var selectedIndices: Set<Int> = []
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    
    struct PDFPageItem: Identifiable {
        let id = UUID()
        let index: Int
        var thumbnail: UIImage?
    }
    
    private var document: PDFDocument?
    let pdf: ConvertedPDF
    let conversionManager: ConversionManager
    
    init(pdf: ConvertedPDF, manager: ConversionManager) {
        self.pdf = pdf
        self.conversionManager = manager
    }
    
    func load() {
        isLoading = true
        errorMessage = nil
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            if let doc = PDFDocument(url: self.pdf.url) {
                let pageCount = doc.pageCount
                // Pre-create items
                var initialItems: [PDFPageItem] = []
                for i in 0..<pageCount {
                    initialItems.append(PDFPageItem(index: i, thumbnail: nil))
                }
                
                let itemsToAssign = initialItems
                await MainActor.run {
                    self.document = doc
                    self.pages = itemsToAssign
                    self.isLoading = false
                }
                
                // Load thumbnails progressively
                let size = CGSize(width: 150, height: 200)
                for i in 0..<pageCount {
                    if let page = doc.page(at: i) {
                        let thumb = page.thumbnail(of: size, for: .mediaBox)
                        await MainActor.run {
                            if i < self.pages.count { self.pages[i].thumbnail = thumb }
                        }
                    }
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Could not open PDF file."
                    self.isLoading = false
                }
            }
        }
    }
    
    func deleteSelected() {
        guard !selectedIndices.isEmpty else { return }
        
        // Remove locally from UI array
        let sortedDesc = selectedIndices.sorted(by: >)
        for idx in sortedDesc {
            pages.remove(at: idx)
        }
        
        // Re-index remaining pages
        for i in 0..<pages.count {
            pages[i] = PDFPageItem(index: i, thumbnail: pages[i].thumbnail)
        }
        
        selectedIndices.removeAll()
    }
    
    func saveChanges(completion: @escaping () -> Void) {
        guard let originalDoc = document else { return }
        isSaving = true
        
        // 1. We have a list of remaining 'pages'. Their 'index' maps to the original PDF page index.
        let remainingOriginalIndices = pages.map { $0.index }
        let originalCount = originalDoc.pageCount
        
        // Find indices to remove (in descending order)
        let setOfRemaining = Set(remainingOriginalIndices)
        let indicesToRemove = (0..<originalCount).filter { !setOfRemaining.contains($0) }.sorted(by: >)
        
        if indicesToRemove.isEmpty {
            isSaving = false
            completion()
            return
        }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            // Remove pages from document
            for idx in indicesToRemove {
                originalDoc.removePage(at: idx)
            }
            
            // Write to disk
            let success = originalDoc.write(to: self.pdf.url)
            
            await MainActor.run {
                if success {
                    Logger.shared.log("PDF Editor: Removed \(indicesToRemove.count) pages from \(self.pdf.name)", category: "Editor")
                    
                    // Update the global ConvertedPDF model
                    var updatedPDF = self.pdf
                    updatedPDF.pageCount = originalDoc.pageCount
                    if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: self.pdf.url.path),
                       let size = fileAttrs[.size] as? Int64 {
                        updatedPDF.fileSize = size
                    }
                    
                    self.conversionManager.updatePDFMetadata(updatedPDF, metadata: updatedPDF.metadata)
                    
                    self.isSaving = false
                    completion()
                } else {
                    self.errorMessage = "Failed to save PDF modifications."
                    self.isSaving = false
                }
            }
        }
    }
}

struct PDFContentEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @StateObject private var viewModel: PDFContentEditorViewModel
    
    init(pdf: ConvertedPDF, manager: ConversionManager) {
        self.pdf = pdf
        _viewModel = StateObject(wrappedValue: PDFContentEditorViewModel(pdf: pdf, manager: manager))
    }
    
    let columns = [GridItem(.adaptive(minimum: 120), spacing: 16)]
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all)
            
            if viewModel.isLoading {
                ProgressView("Loading Pages...")
                    .scaleEffect(1.2)
            } else if let error = viewModel.errorMessage {
                Text(error).foregroundColor(.red)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(viewModel.pages.indices, id: \.self) { idx in
                            let item = viewModel.pages[idx]
                            let isSelected = viewModel.selectedIndices.contains(idx)
                            
                            VStack {
                                ZStack(alignment: .topTrailing) {
                                    if let thumb = item.thumbnail {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 160)
                                            .cornerRadius(6)
                                            .shadow(radius: 2)
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(height: 160)
                                            .cornerRadius(6)
                                            .overlay(ProgressView())
                                    }
                                    
                                    // Selection Overlay
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundColor(isSelected ? .red : .white)
                                        .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.3)))
                                        .padding(8)
                                }
                                .onTapGesture {
                                    if isSelected {
                                        viewModel.selectedIndices.remove(idx)
                                    } else {
                                        viewModel.selectedIndices.insert(idx)
                                    }
                                }
                                
                                Text("Page \(item.index + 1)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                }
            }
            
            if viewModel.isSaving {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                ProgressView("Saving PDF...")
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 10)
            }
        }
        .navigationTitle("Delete Pages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isSaving)
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.selectedIndices.isEmpty {
                    Button(action: {
                        viewModel.deleteSelected()
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    viewModel.saveChanges { dismiss() }
                }
                .disabled(viewModel.isSaving || viewModel.isLoading)
            }
        }
        .onAppear {
            viewModel.load()
        }
    }
}
