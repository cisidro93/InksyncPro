import SwiftUI

struct ShelfSection: View {
    let collection: PDFCollection
    let manager: ConversionManager
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    let onSheet: (LibrarySheetDestination) -> Void

    var pdfs: [ConvertedPDF] {
        manager.visiblePDFs.filter { $0.collectionId == collection.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text(collection.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.inkTextPrimary)
                Spacer()
                Text("\(pdfs.count)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.inkSurfaceRaised)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(pdfs) { pdf in
                        BookCard(
                            pdf: pdf,
                            manager: manager,
                            isSelected: multiSelection.contains(pdf.id),
                            isBatchMode: isBatchMode,
                            onTap: {
                                if isBatchMode {
                                    if multiSelection.contains(pdf.id) {
                                        multiSelection.remove(pdf.id)
                                    } else {
                                        multiSelection.insert(pdf.id)
                                    }
                                } else {
                                    onSheet(.details(pdf))
                                }
                            },
                            onLongPress: {
                                onSheet(.details(pdf))
                            },
                            onContextAction: { action in
                                handleContextAction(action, pdf: pdf)
                            }
                        )
                    }

                    // Add more to this collection
                    AddToCollectionCard(collection: collection) {
                        onSheet(.importer) // Falls back to queue via modern logic, or interception
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 24)
    }

    func handleContextAction(_ action: BookCardAction, pdf: ConvertedPDF) {
        switch action {
        case .convert: onSheet(.export(pdf))
        case .send: onSheet(.completionSend(pdf))
        case .editMetadata: onSheet(.editMetadata(pdf))
        case .searchComicVine: onSheet(.searchMetadata(pdf))
        case .reviewPanels:
            // Trigger PanelEditorView via existing ConversionManager mechanism
            Task { @MainActor in
                // Set the current extraction source and metadata
                manager.isPresentingPanelEditor = true
            }
        case .delete: manager.deletePDF(pdf)
        }
    }
}

enum BookCardAction {
    case convert, send, editMetadata, searchComicVine, reviewPanels, delete
}

struct AddToCollectionCard: View {
    let collection: PDFCollection
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            VStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.inkTextSecondary)
            }
            .frame(width: 88, height: 124)
            .background(Color.inkSurfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
