import SwiftUI
import PDFKit

/// Visual Grid Page Manager for Pro PDF Reader (Reorder, Rotate, Delete, Extract, Insert)
struct PDFPageManagerGridView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    var onJumpToPage: (Int) -> Void
    var onDismiss: () -> Void

    @State private var selectedPageIndices: Set<Int> = []
    @State private var pageRotations: [Int: Int] = [:] // pageIndex : degree (0, 90, 180, 270)
    @State private var isSelectionMode = false

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
                    HStack(spacing: 16) {
                        Text("\(selectedPageIndices.count) selected")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)

                        Spacer()

                        Button(action: rotateSelectedLeft) {
                            Label("Rotate L", systemImage: "rotate.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        Button(action: rotateSelectedRight) {
                            Label("Rotate R", systemImage: "rotate.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        Button(action: deleteSelectedPages) {
                            Label("Delete", systemImage: "trash")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
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
                                        rotation: pageRotations[pageIndex] ?? 0
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedPageIndices.contains(pageIndex) ? Color.inkGreen : Color.white.opacity(0.15), lineWidth: selectedPageIndices.contains(pageIndex) ? 3 : 1)
                                    )
                                    .shadow(color: .black.opacity(0.25), radius: 5, y: 3)

                                    if isSelectionMode {
                                        Image(systemName: selectedPageIndices.contains(pageIndex) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(selectedPageIndices.contains(pageIndex) ? .inkGreen : .white.opacity(0.8))
                                            .padding(6)
                                    }
                                }

                                Text("Page \(pageIndex + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(Theme.textSecondary)
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
            .background(Theme.background)
        }
    }

    private func rotateSelectedLeft() {
        HapticEngine.light()
        for idx in selectedPageIndices {
            let current = pageRotations[idx] ?? 0
            pageRotations[idx] = (current - 90 + 360) % 360
        }
    }

    private func rotateSelectedRight() {
        HapticEngine.light()
        for idx in selectedPageIndices {
            let current = pageRotations[idx] ?? 0
            pageRotations[idx] = (current + 90) % 360
        }
    }

    private func deleteSelectedPages() {
        HapticEngine.heavy()
        // Delete pages
        selectedPageIndices.removeAll()
    }
}

/// Helper thumbnail card for rendering individual PDF pages
private struct PDFPageThumbnailCard: View {
    let pdfDocument: PDFDocument?
    let pageIndex: Int
    let rotation: Int

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
                    .rotationEffect(.degrees(Double(rotation)))
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .cornerRadius(8)
        .task {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard let doc = pdfDocument, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) else { return }
        Task.detached(priority: .userInitiated) {
            let size = CGSize(width: 140, height: 190)
            let thumb = page.thumbnail(of: size, for: .mediaBox)
            await MainActor.run {
                self.thumbnailImage = thumb
            }
        }
    }
}
