import SwiftUI
import PDFKit

// ============================================================================
// MARK: - PAGE REORDER VIEW
// ============================================================================

struct PageReorderView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdf: ConvertedPDF
    @State private var pages: [PageItem] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasChanges = false
    let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)]
    
    var body: some View {
        NavigationView {
            ZStack {
                if isLoading { VStack(spacing: 16) { ProgressView(); Text("Loading pages...").foregroundColor(.secondary) } }
                else { ScrollView { LazyVGrid(columns: columns, spacing: 16) { ForEach(pages) { page in PageThumbnailView(page: page).onDrag { NSItemProvider(object: page.id.uuidString as NSString) }.onDrop(of: [.text], delegate: PageDropDelegate(item: page, items: $pages, hasChanges: $hasChanges)) } }.padding() } }
                if isSaving { Color.black.opacity(0.5).ignoresSafeArea(); VStack(spacing: 16) { ProgressView().scaleEffect(1.5); Text("Saving changes...").foregroundColor(.white).fontWeight(.medium) } }
            }
            .navigationTitle("Reorder Pages").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { saveChanges() }.fontWeight(.semibold).disabled(!hasChanges || isSaving) } }
            .onAppear { loadPages() }
        }
    }
    
    private func loadPages() {
        Task {
            if pdf.url.pathExtension.lowercased() == "epub" {
                do {
                    let urls = try await conversionManager.extractImageURLs(from: pdf.url)
                    var loadedPages: [PageItem] = []
                    // Resize for thumbnail optimization usually done by UIImage instantiation?
                    // We'll just load them. For 100 pages it might be heavy memory-wise if we load full images.
                    // But for "thumbnailSize", we should downscale.
                    
                    for (i, url) in urls.enumerated() {
                        if let image = UIImage(contentsOfFile: url.path) {
                             // Downscale
                             let targetSize = CGSize(width: 100, height: 140)
                             let renderer = UIGraphicsImageRenderer(size: targetSize)
                             let thumbnail = renderer.image { _ in
                                 image.draw(in: CGRect(origin: .zero, size: targetSize))
                             }
                             loadedPages.append(PageItem(originalIndex: i, currentIndex: i, thumbnail: thumbnail))
                        }
                    }
                    await MainActor.run { pages = loadedPages; isLoading = false }
                } catch {
                    print("Failed to load EPUB pages: \(error)")
                    await MainActor.run { isLoading = false }
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let document = PDFDocument(url: pdf.url) else { return }
                    var loadedPages: [PageItem] = []
                    let thumbnailSize = CGSize(width: 100, height: 140)
                    for i in 0..<document.pageCount {
                         if let page = document.page(at: i) {
                             let thumbnail = page.thumbnail(of: thumbnailSize, for: .mediaBox)
                             loadedPages.append(PageItem(originalIndex: i, currentIndex: i, thumbnail: thumbnail))
                         }
                    }
                    DispatchQueue.main.async { pages = loadedPages; isLoading = false }
                }
            }
        }
    }
    
    private func saveChanges() {
        isSaving = true
        let newOrder = pages.map { $0.originalIndex }
        Task { do { _ = try await conversionManager.reorderPages(in: pdf.url, newOrder: newOrder); await MainActor.run { isSaving = false; dismiss() } } catch { await MainActor.run { isSaving = false } } }
    }
}

struct PageThumbnailView: View {
    let page: PageItem
    var body: some View {
        VStack(spacing: 4) { Image(uiImage: page.thumbnail).resizable().aspectRatio(contentMode: .fit).frame(height: 120).cornerRadius(6).shadow(radius: 2).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1)); Text("\(page.currentIndex + 1)").font(.caption).foregroundColor(.secondary) }
    }
}

struct PageDropDelegate: DropDelegate {
    let item: PageItem
    @Binding var items: [PageItem]
    @Binding var hasChanges: Bool
    func performDrop(info: DropInfo) -> Bool { hasChanges = true; return true }
    func dropEntered(info: DropInfo) { guard let fromIndex = items.firstIndex(where: { $0.id == item.id }) else { return }; let toIndex = items.firstIndex(where: { $0.id == item.id }) ?? 0; if fromIndex != toIndex { withAnimation { items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex); for i in 0..<items.count { items[i].currentIndex = i } }; hasChanges = true } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
