import SwiftUI
import PDFKit

struct PageDeleteView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdf: ConvertedPDF
    
    @State private var pages: [DeletablePageItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showingDeleteConfirmation = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    private var selectedCount: Int { pages.filter { $0.isSelected }.count }
    private var hasSelection: Bool { selectedCount > 0 }
    private var canDelete: Bool { selectedCount > 0 && selectedCount < pages.count }
    
    let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)]
    
    var body: some View {
        NavigationView {
            ZStack {
                if isLoading {
                    VStack(spacing: 16) { ProgressView(); Text("Loading pages...").foregroundColor(.secondary) }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            if hasSelection { Image(systemName: "checkmark.circle.fill").foregroundColor(.red); Text("\(selectedCount) page\(selectedCount > 1 ? "s" : "") selected").fontWeight(.medium) }
                            else { Image(systemName: "hand.tap").foregroundColor(.secondary); Text("Tap pages to select for deletion") }
                            Spacer()
                            Text("\(pages.count) total").font(.caption).foregroundColor(.secondary)
                        }.padding().background(Color(.secondarySystemBackground))
                        
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach($pages) { $page in DeletablePageThumbnail(page: $page) }
                            }.padding()
                        }
                        
                        if hasSelection {
                            VStack(spacing: 12) {
                                if !canDelete && selectedCount == pages.count {
                                    HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange); Text("You must keep at least 1 page").font(.caption).foregroundColor(.orange) }
                                }
                                Button(action: { showingDeleteConfirmation = true }) {
                                    HStack { Image(systemName: "trash.fill"); Text("Delete \(selectedCount) Page\(selectedCount > 1 ? "s" : "")").fontWeight(.semibold) }
                                    .foregroundColor(.white).frame(maxWidth: .infinity).padding().background(canDelete ? Color.red : Color.gray).cornerRadius(12)
                                }.disabled(!canDelete).padding(.horizontal).padding(.bottom)
                            }.background(Color(.systemBackground).shadow(radius: 2))
                        }
                    }
                }
                if isSaving { Color.black.opacity(0.5).ignoresSafeArea(); VStack(spacing: 16) { ProgressView().scaleEffect(1.5); Text("Removing pages...").foregroundColor(.white).fontWeight(.medium) } }
            }
            .navigationTitle("Delete Pages").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { for i in 0..<pages.count { pages[i].isSelected = true } }) { Label("Select All", systemImage: "checkmark.circle.fill") }
                        Button(action: { for i in 0..<pages.count { pages[i].isSelected = false } }) { Label("Deselect All", systemImage: "circle") }
                        Divider()
                        Button(action: { for i in 0..<pages.count { pages[i].isSelected = (i + 1) % 2 == 0 } }) { Label("Select Even Pages", systemImage: "number.circle") }
                        Button(action: { for i in 0..<pages.count { pages[i].isSelected = (i + 1) % 2 == 1 } }) { Label("Select Odd Pages", systemImage: "number.circle.fill") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onAppear { loadPages() }
            .alert("Delete Pages", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete \(selectedCount) Page\(selectedCount > 1 ? "s" : "")", role: .destructive) { deleteSelectedPages() }
            } message: { Text("Are you sure you want to delete \(selectedCount) page\(selectedCount > 1 ? "s" : "")? This cannot be undone.") }
            .alert("Status", isPresented: $showingAlert) { Button("OK") { dismiss() } } message: { Text(alertMessage) }
        }
    }
    
    private func loadPages() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            // PDF Handling
            if pdf.url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: pdf.url) else { DispatchQueue.main.async { isLoading = false }; return }
                var loadedPages: [DeletablePageItem] = []
                let thumbnailSize = CGSize(width: 100, height: 140)
                for i in 0..<document.pageCount {
                    if let page = document.page(at: i) {
                        let thumbnail = page.thumbnail(of: thumbnailSize, for: .mediaBox)
                        loadedPages.append(DeletablePageItem(pageIndex: i, thumbnail: thumbnail, isSelected: false))
                    }
                }
                DispatchQueue.main.async { pages = loadedPages; isLoading = false }
            } 
            // EPUB Handling
            else if pdf.url.pathExtension.lowercased() == "epub" {
                Task {
                    do {
                        let imageURLs = try await conversionManager.extractImageURLs(from: pdf.url)
                        var loadedPages: [DeletablePageItem] = []
                        let thumbnailSize = CGSize(width: 100, height: 140)
                        
                        for (index, url) in imageURLs.enumerated() {
                            if let image = UIImage(contentsOfFile: url.path) {
                                // Create thumbnail efficiently
                                let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
                                let thumbnail = renderer.image { _ in
                                    image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
                                }
                                var item = DeletablePageItem(pageIndex: index, thumbnail: thumbnail, isSelected: false)
                                item.imageURL = url
                                loadedPages.append(item)
                            }
                        }
                        let finalPages = loadedPages
                        await MainActor.run { pages = finalPages; isLoading = false }
                    } catch {
                        await MainActor.run { isLoading = false; alertMessage = "Failed to load EPUB pages: \(error.localizedDescription)"; showingAlert = true }
                    }
                }
            }
        }
    }
    
    private func deleteSelectedPages() {
        isSaving = true
        let pagesToKeep = pages.enumerated().filter { !$0.element.isSelected }.map { $0.element.pageIndex }
        
        Task {
            do {
                if pdf.url.pathExtension.lowercased() == "pdf" {
                    try await removePagesFromPDF(at: pdf.url, keepingPages: pagesToKeep)
                } else {
                    let keepingImageURLs = pages.filter { !$0.isSelected }.compactMap { $0.imageURL }
                    try await removePagesFromEPUB(at: pdf.url, keepingImageURLs: keepingImageURLs)
                }
                
                // Update local list
                await MainActor.run {
                    pages = pages.filter { !$0.isSelected }
                    // Re-index remaining pages
                    var newPages: [DeletablePageItem] = []
                    for (index, item) in pages.enumerated() {
                        newPages.append(DeletablePageItem(pageIndex: index, thumbnail: item.thumbnail, isSelected: false, imageURL: item.imageURL))
                    }
                    pages = newPages
                    
                    isSaving = false
                    alertMessage = "Successfully removed \(selectedCount) page\(selectedCount > 1 ? "s" : "")!"
                    showingAlert = true
                }
            } catch {
                await MainActor.run { isSaving = false; alertMessage = "Failed to delete pages: \(error.localizedDescription)"; showingAlert = true }
            }
        }
    }
    
    private func removePagesFromPDF(at url: URL, keepingPages indices: [Int]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let document = PDFDocument(url: url) else { continuation.resume(throwing: NSError(domain: "PageDelete", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF"])); return }
                let newDocument = PDFDocument()
                for (newIndex, oldIndex) in indices.enumerated() { if let page = document.page(at: oldIndex) { newDocument.insert(page, at: newIndex) } }
                if newDocument.write(to: url) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "PageDelete", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not save PDF"]))
                }
            }
        }
        
        await MainActor.run {
            if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[index].pageCount = indices.count
                conversionManager.savePDFs()
            }
        }
    }
    
    // Force re-sync of file structure
    private func removePagesFromEPUB(at url: URL, keepingImageURLs: [URL]) async throws {
        // Create settings
        let settings = conversionManager.conversionSettings.epubSettings
        let generator = EPUBGenerator(settings: settings, metadata: pdf.metadata, compressionQuality: 1.0) // Maintain quality
        
        // Generate new EPUB to temp location
        let (tempOutputURL, generatedPageCount) = try await generator.generateEPUB(from: keepingImageURLs, outputName: pdf.name)
        
        // Output handler to overwrite original
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempOutputURL, to: url)
        
        // Update valid page count in library
        await MainActor.run {
            if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[index].pageCount = generatedPageCount
                conversionManager.savePDFs()
            }
        }
    }
}

struct DeletablePageThumbnail: View {
    @Binding var page: DeletablePageItem
    
    var body: some View {
        Button(action: { page.isSelected.toggle() }) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Image(uiImage: page.thumbnail).resizable().aspectRatio(contentMode: .fit).frame(height: 120).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(page.isSelected ? Color.red : Color.gray.opacity(0.3), lineWidth: page.isSelected ? 3 : 1))
                        .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(page.isSelected ? 0.2 : 0)))
                        .shadow(radius: 2)
                    Text("\(page.pageIndex + 1)").font(.caption).foregroundColor(page.isSelected ? .red : .secondary).fontWeight(page.isSelected ? .bold : .regular)
                }
                if page.isSelected {
                    ZStack { Circle().fill(Color.white).frame(width: 24, height: 24); Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundColor(.red) }.offset(x: 6, y: -6)
                }
            }
        }.buttonStyle(PlainButtonStyle())
    }
}
