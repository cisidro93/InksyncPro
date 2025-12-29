import SwiftUI
import PDFKit

// ============================================================================
// MARK: - PDF PREVIEW VIEW
// ============================================================================

struct PDFPreviewView: View {
    let pdf: ConvertedPDF
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    @State private var totalPages = 0
    @State private var showingPagePicker = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                PDFKitView(url: pdf.url, currentPage: $currentPage, totalPages: $totalPages).ignoresSafeArea(edges: .bottom)
                bottomToolbar
            }
            .navigationTitle(pdf.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Done") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { Menu { Button(action: { sharePDF() }) { Label("Share", systemImage: "square.and.arrow.up") }; Button(action: { showingPagePicker = true }) { Label("Go to Page", systemImage: "arrow.right.doc.on.clipboard") } } label: { Image(systemName: "ellipsis.circle") } } }
            .sheet(isPresented: $showingPagePicker) { PagePickerView(currentPage: $currentPage, totalPages: totalPages) }
        }
    }
    
    private var bottomToolbar: some View {
        VStack(spacing: 8) {
            if totalPages > 1 { HStack { Text("1").font(.caption).foregroundColor(.secondary); Slider(value: Binding(get: { Double(currentPage) }, set: { currentPage = Int($0) }), in: 0...Double(max(totalPages - 1, 1)), step: 1).tint(.orange); Text("\(totalPages)").font(.caption).foregroundColor(.secondary) }.padding(.horizontal) }
            HStack {
                Button(action: { if currentPage > 0 { currentPage -= 1 } }) { Image(systemName: "chevron.left").font(.title3).foregroundColor(currentPage > 0 ? .orange : .gray) }.disabled(currentPage == 0)
                Spacer()
                Text("Page \(currentPage + 1) of \(totalPages)").font(.subheadline).fontWeight(.medium)
                Spacer()
                Button(action: { if currentPage < totalPages - 1 { currentPage += 1 } }) { Image(systemName: "chevron.right").font(.title3).foregroundColor(currentPage < totalPages - 1 ? .orange : .gray) }.disabled(currentPage >= totalPages - 1)
            }.padding(.horizontal, 30)
        }.padding(.vertical, 12).background(Color(.systemBackground).shadow(radius: 2))
    }
    
    private func sharePDF() { let activityVC = UIActivityViewController(activityItems: [pdf.url], applicationActivities: nil); if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let rootViewController = windowScene.windows.first?.rootViewController { rootViewController.present(activityVC, animated: true) } }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true)
        pdfView.backgroundColor = UIColor.systemBackground
        if let document = PDFDocument(url: url) { pdfView.document = document; DispatchQueue.main.async { totalPages = document.pageCount } }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        return pdfView
    }
    func updateUIView(_ pdfView: PDFView, context: Context) { if let document = pdfView.document, let page = document.page(at: currentPage), pdfView.currentPage != page { pdfView.go(to: page) } }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject {
        var parent: PDFKitView
        init(_ parent: PDFKitView) { self.parent = parent }
        @objc func pageChanged(_ notification: Notification) { guard let pdfView = notification.object as? PDFView, let currentPage = pdfView.currentPage, let document = pdfView.document, let pageIndex = document.index(for: currentPage) else { return }; DispatchQueue.main.async { self.parent.currentPage = pageIndex } }
    }
}

struct PagePickerView: View {
    @Binding var currentPage: Int
    let totalPages: Int
    @Environment(\.dismiss) private var dismiss
    @State private var inputPage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Go to Page").font(.headline)
                TextField("Page number", text: $inputPage).keyboardType(.numberPad).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 150).multilineTextAlignment(.center)
                Text("Enter a number between 1 and \(totalPages)").font(.caption).foregroundColor(.secondary)
                Button("Go") { if let page = Int(inputPage), page >= 1, page <= totalPages { currentPage = page - 1; dismiss() } }.buttonStyle(.borderedProminent).tint(.orange).disabled(Int(inputPage) == nil || Int(inputPage)! < 1 || Int(inputPage)! > totalPages)
                Spacer()
            }.padding(.top, 40).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.height(250)])
    }
}
