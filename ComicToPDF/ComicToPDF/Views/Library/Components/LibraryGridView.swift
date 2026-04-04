import SwiftUI

struct LibraryGridView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    
    let items: [LibraryListItem]
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    let useNavigationStack: Bool
    @Binding var tapAction: LibraryTapAction
    @Binding var selectedPDF: ConvertedPDF?
    
    // Action callback to bubble events up to ModernLibraryView where the sheets live
    let onAction: (LibraryRowAction, ConvertedPDF) -> Void
    let onImport: () -> Void
    
    // Series rename state — driven by SeriesViewModel which lives in parent
    @State private var renamingGroup: SeriesGroup? = nil
    @State private var pendingSeriesName: String = ""
    
    var body: some View {
        Group {
            if conversionManager.visiblePDFs.isEmpty {
                ModernEmptyState(onImport: onImport, onFolderImport: nil)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                // Adaptive grid sizing: roughly 3 columns on phone, 5-6 on iPad
                let minWidth: CGFloat = hSizeClass == .regular ? 160 : 100
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: 280), spacing: 16)], spacing: 20) {
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
                                    ModernGridSeriesCell(group: group, isSelected: group.issues.allSatisfy { multiSelection.contains($0.id) }, isBatch: true)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack)) {
                                    ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .contextMenu {
                                    Button {
                                        pendingSeriesName = group.title
                                        renamingGroup = group
                                    } label: { Label("Rename Series", systemImage: "pencil") }
                                    
                                    Divider()
                                    
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
                                    ModernGridFileCell(pdf: pdf, isSelected: multiSelection.contains(pdf.id), isBatch: true)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                if useNavigationStack && tapAction == .details {
                                    NavigationLink(value: pdf) {
                                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .contextMenu { contextMenuContent(pdf) }
                                } else {
                                    Button {
                                        if tapAction == .read {
                                            onAction(.read, pdf)
                                        } else {
                                            onAction(.details, pdf) // Triggers details using ModernLibraryView state
                                        }
                                    } label: {
                                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .contextMenu { contextMenuContent(pdf) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
            .background(Color.black)
            .overlay(alignment: .trailing) {
                // ✅ PHASE 10: Comic Zeal Feature Restored
                ComicZealScrubber { letter in
                    if let targetID = firstItemId(for: letter) {
                        withAnimation { proxy.scrollTo(targetID, anchor: .top) }
                    }
                }
                .padding(.vertical, 30)
                .padding(.trailing, 2)
            }
            } // End ScrollViewReader
            }
        }
        .alert("Rename Series", isPresented: Binding<Bool>(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Series Name", text: $pendingSeriesName)
                .autocorrectionDisabled()
            Button("Rename") {
                guard let group = renamingGroup else { return }
                let newName = pendingSeriesName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty, newName != group.title else { renamingGroup = nil; return }
                for pdf in group.issues {
                    if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                        conversionManager.convertedPDFs[idx].metadata.series = newName
                    }
                }
                conversionManager.saveLibrary()
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        } message: {
            Text("This will rename all \(renamingGroup?.count ?? 0) issues in this series.")
        }
    }
    
    // ✅ NEW: Fast Index Search
    private func firstItemId(for letter: String) -> String? {
        if letter == "#" {
            return items.first { item in
                let title: String
                switch item {
                case .series(let group): title = group.title
                case .single(let pdf): title = pdf.name
                }
                guard let firstChar = title.first else { return false }
                return firstChar.isNumber || !firstChar.isLetter
            }?.id
        }
        
        return items.first { item in
            let title: String
            switch item {
            case .series(let group): title = group.title
            case .single(let pdf): title = pdf.name
            }
            return title.uppercased().hasPrefix(letter)
        }?.id
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
            onAction(.toggleVault, pdf)
        } label: { Label(pdf.isPrivate ? "Remove from Vault" : "Move to Vault", systemImage: pdf.isPrivate ? "lock.open" : "lock.fill") }
        
        Button {
            onAction(.editMetadata, pdf)
        } label: { Label("Edit Metadata & Cover", systemImage: "pencil.and.list.clipboard") }
        
        Button {
            onAction(.fetchMetadata, pdf) // using fetchMetadata here to pop Media Details
        } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
    }
}
