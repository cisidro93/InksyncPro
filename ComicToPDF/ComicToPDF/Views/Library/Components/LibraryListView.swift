import SwiftUI

struct LibraryListView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    let items: [LibraryListItem]
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    let useNavigationStack: Bool
    @Binding var tapAction: LibraryTapAction
    @Binding var selectedPDF: ConvertedPDF?
    
    // Action callback to bubble events up to ModernLibraryView where the sheets live
    let onAction: (LibraryRowAction, ConvertedPDF) -> Void
    let onImport: () -> Void
    
    var body: some View {
        if conversionManager.visiblePDFs.isEmpty {
            ModernEmptyState(onImport: onImport, onFolderImport: nil)
        } else {
            List(selection: useNavigationStack ? nil : $selectedPDF) {
                ForEach(items) { item in
                    switch item {
                    case .series(let group):
                        if isBatchMode {
                            Button {
                                let allSelected = group.issues.allSatisfy { multiSelection.contains($0.id) }
                                if allSelected {
                                    for issue in group.issues { multiSelection.remove(issue.id) }
                                } else {
                                    for issue in group.issues { multiSelection.insert(issue.id) }
                                }
                            } label: {
                                ModernSeriesRow(group: group, isSelected: group.issues.allSatisfy { multiSelection.contains($0.id) }, isBatch: true)
                            }
                            .listRowBackground(Color.black)
                            .listRowSeparatorTint(Color(white: 0.2))
                        } else {
                            NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack)) {
                                ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                            }
                            .listRowBackground(Color.black)
                            .listRowSeparatorTint(Color(white: 0.2))
                            .contextMenu {
                                Button(role: .destructive) {
                                    for issue in group.issues { conversionManager.deletePDF(issue) }
                                } label: { Label("Delete Series", systemImage: "trash") }
                            }
                            // ✅ Comic Zeal Swipe Selection Action (Swipe Left)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    isBatchMode = true
                                    for issue in group.issues { multiSelection.insert(issue.id) }
                                } label: {
                                    Label("Select Group", systemImage: "checkmark.circle.fill")
                                }
                                .tint(.green)
                                
                                Button(role: .destructive) {
                                    for issue in group.issues { conversionManager.deletePDF(issue) }
                                } label: { Label("Delete Series", systemImage: "trash") }
                            }
                        }
                    case .single(let pdf):
                        if isBatchMode {
                             Button {
                                 if multiSelection.contains(pdf.id) {
                                     multiSelection.remove(pdf.id)
                                 } else {
                                     multiSelection.insert(pdf.id)
                                 }
                             } label: {
                                 ModernFileRow(pdf: pdf, isSelected: multiSelection.contains(pdf.id), isBatch: true)
                             }
                             .listRowBackground(Color.black)
                             .listRowSeparatorTint(Color(white: 0.2))
                        } else {
                            if useNavigationStack && tapAction == .details {
                                NavigationLink(value: pdf) {
                                    ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                                }
                                .listRowBackground(Color.black)
                                .listRowSeparatorTint(Color(white: 0.2))
                                // ✅ Comic Zeal Swipe Selection Action (Swipe Left)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        isBatchMode = true
                                        multiSelection.insert(pdf.id)
                                    } label: { Label("Select", systemImage: "checkmark.circle.fill") }
                                    .tint(.green)
                                    
                                    swipeActionsTrailing(pdf)
                                }
                                .swipeActions(edge: .leading) {
                                    swipeActionsLeading(pdf)
                                }
                                .contextMenu {
                                    contextMenuContent(pdf)
                                }
                            } else {
                                Button {
                                    if tapAction == .read {
                                        onAction(.read, pdf)
                                    } else {
                                        onAction(.fetchMetadata, pdf) // using fetchMetadata here to trigger details, wait ModernLibraryView uses pdfForDetails
                                    }
                                } label: {
                                    ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                                }
                                .tag(pdf)
                                .listRowBackground(Color.black)
                                .listRowSeparatorTint(Color(white: 0.2))
                                // ✅ Comic Zeal Swipe Selection Action (Swipe Left)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        isBatchMode = true
                                        multiSelection.insert(pdf.id)
                                    } label: { Label("Select", systemImage: "checkmark.circle.fill") }
                                    .tint(.green)
                                    
                                    swipeActionsTrailing(pdf)
                                }
                                .swipeActions(edge: .leading) {
                                    swipeActionsLeading(pdf)
                                }
                                .contextMenu {
                                    contextMenuContent(pdf)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.black)
        }
    }
    
    @ViewBuilder
    private func swipeActionsLeading(_ pdf: ConvertedPDF) -> some View {
        Button {
            onAction(.share, pdf)
        } label: { Label("Send to App", systemImage: "paperplane") }
        .tint(.blue)
    
        Button {
            onAction(.fetchMetadata, pdf) // Or a specific metadata action
        } label: { Label("Metadata", systemImage: "info.circle") }
        .tint(.blue)
        
        Button {
            onAction(.favorite, pdf)
        } label: { Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash.fill" : "star.fill") }
        .tint(.yellow)
        
        Button {
            onAction(.rename, pdf)
        } label: { Label("Rename", systemImage: "pencil") }
        .tint(.orange)
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed", systemImage: "flame") }
        .tint(.purple)
    }
    
    @ViewBuilder
    private func swipeActionsTrailing(_ pdf: ConvertedPDF) -> some View {
        Button(role: .destructive) { onAction(.delete, pdf) } label: { Label("Delete", systemImage: "trash") }
    }
    
    @ViewBuilder
    private func contextMenuContent(_ pdf: ConvertedPDF) -> some View {
        Button {
            onAction(.read, pdf)
        } label: { Label("Read / Preview", systemImage: "book.pages") }
        
        Button {
            onAction(.covers, pdf)
        } label: { Label("Edit Workspace (Covers)", systemImage: "paintbrush.pointed") }
        
        Button {
            onAction(.favorite, pdf)
        } label: { Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star") }
        
        Button {
            onAction(.export, pdf)
        } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        
        Button {
            onAction(.share, pdf)
        } label: { Label("Send to Kindle / Share", systemImage: "paperplane") }
        
        Button {
            onAction(.sync, pdf)
        } label: { Label("Direct Cloud Sync", systemImage: "icloud.and.arrow.up") }
        
        Button {
            onAction(.rename, pdf)
        } label: { Label("Rename", systemImage: "pencil") }
        
        // Layer 4: Manual series assignment
        Button {
            onAction(.addToSeries, pdf)
        } label: { Label("Add to Series...", systemImage: "books.vertical") }
        
        // Show Cover Select only if the PDF is part of a series or collection
        if (pdf.metadata.series != nil && !pdf.metadata.series!.isEmpty) || pdf.collectionId != nil {
            Button {
                conversionManager.setExplicitSeriesCover(for: pdf)
            } label: { Label("Set as Series Cover", systemImage: "photo.on.rectangle") }
        }
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed Panels", systemImage: "flame") }
        
        Button(role: .destructive) { onAction(.delete, pdf) } label: { Label("Delete", systemImage: "trash") }
        Divider()
        
        Button {
            onAction(.editMetadata, pdf)
        } label: { Label("Edit Metadata & Cover", systemImage: "pencil.and.list.clipboard") }
        
        Button {
            onAction(.fetchMetadata, pdf)
        } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
    }
}
