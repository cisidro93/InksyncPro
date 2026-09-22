import SwiftUI
import PDFKit

/// Visual Grid Page Manager for Pro PDF Reader (Reorder, Rotate, Delete, Extract, Insert)
struct PDFPageManagerGridView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    var onJumpToPage: (Int) -> Void
    var onDismiss: () -> Void
    var onDocumentModified: (() -> Void)? = nil

    @State private var selectedPageIndices: Set<Int> = []
    @State private var pageRotations: [Int: Int] = [:]
    @State private var isSelectionMode = false
    @State private var showDeleteConfirmation = false
    @State private var gridRefreshID = UUID()
    @State private var isSaving = false

    private var totalPages: Int {
        pdfDocument?.pageCount ?? pdf.pageCount
    }

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Action Control Bar
                if isSelectionMode {
                    VStack(spacing: 0) {
                        HStack(spacing: 16) {
                            Text("\(selectedPageIndices.count) selected")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color.inkText)

                            Spacer()

                            Button(action: rotateSelectedLeft) {
                                Label("Rotate L", systemImage: "rotate.left")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color.inkText)
                            }
                            .disabled(selectedPageIndices.isEmpty)

                            Button(action: rotateSelectedRight) {
                                Label("Rotate R", systemImage: "rotate.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color.inkText)
                            }
                            .disabled(selectedPageIndices.isEmpty)

                            Button(action: { showDeleteConfirmation = true }) {
                                Label("Delete", systemImage: "trash")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(selectedPageIndices.isEmpty ? Color.inkSecondary : Color.inkRed)
                            }
                            .disabled(selectedPageIndices.isEmpty || (pdfDocument?.pageCount ?? 1) <= 1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        
                        Rectangle()
                            .fill(Color.inkBorderSubtle)
                            .frame(height: 0.5)
                    }
                    .background(Color.inkSurfaceRaised)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Page Thumbnails Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<totalPages, id: \.self) { pageIndex in
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    // Render Page Thumbnail
                                    PDFPageThumbnailCard(
                                        pdfDocument: pdfDocument,
                                        pageIndex: pageIndex,
                                        rotation: pageRotations[pageIndex] ?? (pdfDocument?.page(at: pageIndex)?.rotation ?? 0),
                                        refreshID: gridRefreshID
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedPageIndices.contains(pageIndex) ? Color.inkGreen : Color.inkBorderSubtle, lineWidth: selectedPageIndices.contains(pageIndex) ? 3 : 1)
                                    )
                                    .shadow(color: .black.opacity(0.18), radius: 5, y: 3)

                                    if isSelectionMode {
                                        Image(systemName: selectedPageIndices.contains(pageIndex) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(selectedPageIndices.contains(pageIndex) ? .inkGreen : Color.inkSecondary)
                                            .padding(6)
                                    }
                                }

                                Text("Page \(pageIndex + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(Color.inkSecondary)
                            }
                            .onTapGesture {
                                if isSelectionMode {
                                    HapticEngine.light()
                                    if selectedPageIndices.contains(pageIndex) {
                                        selectedPageIndices.remove(pageIndex)
                                    } else {
                                        selectedPageIndices.insert(pageIndex)
                                    }
                                } else {
                                    HapticEngine.medium()
                                    onJumpToPage(pageIndex)
                                    onDismiss()
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .id(gridRefreshID)
            }
            .navigationTitle("Page Manager (\(totalPages) pages)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onDismiss()
                    }
                    .foregroundColor(.inkGreen)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSelectionMode ? "Done" : "Select") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedPageIndices.removeAll()
                            }
                        }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.inkGreen)
                }
            }
            .background(Color.inkBackground)
            .alert("Delete \(selectedPageIndices.count) Page(s)?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    performDeleteSelectedPages()
                }
            } message: {
                Text("This will permanently remove the selected pages from this PDF file.")
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                            Text("Saving Changes...")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .allowsHitTesting(!isSaving)
        }
    }

    private func rotateSelectedLeft() {
        guard let doc = pdfDocument, !selectedPageIndices.isEmpty else { return }
        HapticEngine.light()
        for idx in selectedPageIndices {
            if let page = doc.page(at: idx) {
                let current = (page.rotation - 90 + 360) % 360
                page.rotation = current
                pageRotations[idx] = current
            }
        }
        persistDocumentChanges()
    }

    private func rotateSelectedRight() {
        guard let doc = pdfDocument, !selectedPageIndices.isEmpty else { return }
        HapticEngine.light()
        for idx in selectedPageIndices {
            if let page = doc.page(at: idx) {
                let current = (page.rotation + 90) % 360
                page.rotation = current
                pageRotations[idx] = current
            }
        }
        persistDocumentChanges()
    }

    private func performDeleteSelectedPages() {
        guard let doc = pdfDocument, !selectedPageIndices.isEmpty else { return }
        HapticEngine.heavy()
        let sortedDesc = selectedPageIndices.sorted(by: >)
        for idx in sortedDesc {
            if idx < doc.pageCount && doc.pageCount > 1 {
                doc.removePage(at: idx)
            }
        }
        selectedPageIndices.removeAll()
        pageRotations.removeAll()
        persistDocumentChanges()
    }

    private func persistDocumentChanges() {
        guard let doc = pdfDocument else { return }
        isSaving = true
        let targetPDF = pdf
        let newPageCount = doc.pageCount
        guard let pdfData = doc.dataRepresentation() else {
            isSaving = false
            return
        }

        Task {
            let writeSuccess: Bool
            if case .linked(let bookmarkData) = targetPDF.sourceMode {
                do {
                    writeSuccess = try await BookmarkResolver.shared.withWriteAccess(bookmarkData) { writeURL in
                        try pdfData.write(to: writeURL, options: .atomic)
                        return true
                    }
                } catch {
                    Logger.shared.log("PDFPageManagerGridView: Linked write failed: \(error.localizedDescription)", category: "PDFPageManager", type: .error)
                    writeSuccess = false
                }
            } else {
                writeSuccess = await Task.detached(priority: .userInitiated) { [pdfData, targetURL = targetPDF.url] () -> Bool in
                    do {
                        try pdfData.write(to: targetURL, options: .atomic)
                        return true
                    } catch {
                        Logger.shared.log("PDFPageManagerGridView: Local write failed: \(error.localizedDescription)", category: "PDFPageManager", type: .error)
                        return false
                    }
                }.value
            }

            if writeSuccess {
                ConversionManager.shared.updatePDFPageCount(targetPDF.id, newPageCount: newPageCount)
            }
            self.gridRefreshID = UUID()
            self.isSaving = false
            self.onDocumentModified?()
        }
    }
}

/// Helper thumbnail card for rendering individual PDF pages
private struct PDFPageThumbnailCard: View {
    let pdfDocument: PDFDocument?
    let pageIndex: Int
    let rotation: Int
    let refreshID: UUID

    @State private var thumbnailImage: UIImage? = nil

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
                .aspectRatio(0.72, contentMode: .fit)

            if let img = thumbnailImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .cornerRadius(8)
        .task(id: "\(pageIndex)_\(rotation)_\(refreshID)") {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard let doc = pdfDocument, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) else { return }
        Task {
            let size = CGSize(width: 140, height: 190)
            let thumb = await Task.detached(priority: .userInitiated) { () -> UIImage in
                return page.thumbnail(of: size, for: .mediaBox)
            }.value
            if !Task.isCancelled {
                self.thumbnailImage = thumb
            }
        }
    }
}
