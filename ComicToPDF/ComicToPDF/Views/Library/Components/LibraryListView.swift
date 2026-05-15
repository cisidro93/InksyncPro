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
    let onFolderTap: (UUID?) -> Void
    
    var body: some View {
        if conversionManager.visiblePDFs.isEmpty {
            ModernEmptyState(onImport: onImport, onFolderImport: nil)
        } else {
            ScrollViewReader { proxy in
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
                            .listRowBackground(Theme.bg)
                            .listRowSeparatorTint(Color(UIColor.separator))
                        } else {
                            if let folderUUID = UUID(uuidString: group.id) {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        onFolderTap(folderUUID)
                                    }
                                } label: {
                                    ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                                }
                                .listRowBackground(Theme.bg)
                                .listRowSeparatorTint(Color(UIColor.separator))
                                .contextMenu {
                                    Button {
                                        if let next = nextUnread(in: group) {
                                            HapticEngine.success()
                                            onAction(.read, next)
                                        }
                                    } label: { Label("Read Next Issue", systemImage: "play.fill") }
                                    Divider()
                                    Button {
                                        NotificationCenter.default.post(name: Notification.Name("RequestSeriesRename"), object: group)
                                    } label: { Label("Rename Folder", systemImage: "pencil") }
                                    Divider()
                                    Button(role: .destructive) {
                                        for issue in group.issues { conversionManager.deletePDF(issue) }
                                    } label: { Label("Delete Folder", systemImage: "trash") }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        if let next = nextUnread(in: group) {
                                            HapticEngine.success()
                                            onAction(.read, next)
                                        }
                                    } label: { Label("Read Next", systemImage: "play.fill") }
                                    .tint(Color.inkBlue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        isBatchMode = true
                                        for issue in group.issues { multiSelection.insert(issue.id) }
                                    } label: { Label("Select Group", systemImage: "checkmark.circle.fill") }
                                    .tint(.green)
                                    Button(role: .destructive) {
                                        for issue in group.issues { conversionManager.deletePDF(issue) }
                                    } label: { Label("Delete Folder", systemImage: "trash") }
                                }
                            } else {
                                NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack)) {
                                    ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                                }
                                .listRowBackground(Theme.bg)
                                .listRowSeparatorTint(Color(UIColor.separator))
                                .contextMenu {
                                    Button {
                                        if let next = nextUnread(in: group) {
                                            HapticEngine.success()
                                            onAction(.read, next)
                                        }
                                    } label: { Label("Read Next Issue", systemImage: "play.fill") }

                                    Divider()

                                    Button {
                                        NotificationCenter.default.post(name: Notification.Name("RequestSeriesRename"), object: group)
                                    } label: { Label("Rename Series", systemImage: "pencil") }

                                    Divider()

                                    Button(role: .destructive) {
                                        for issue in group.issues { conversionManager.deletePDF(issue) }
                                    } label: { Label("Delete Series", systemImage: "trash") }
                                }
                                // Swipe right → Read next unread issue immediately
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        if let next = nextUnread(in: group) {
                                            HapticEngine.success()
                                            onAction(.read, next)
                                        }
                                    } label: { Label("Read Next", systemImage: "play.fill") }
                                    .tint(Color.inkBlue)
                                }
                                // Swipe left → select all or delete
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        isBatchMode = true
                                        for issue in group.issues { multiSelection.insert(issue.id) }
                                    } label: { Label("Select Group", systemImage: "checkmark.circle.fill") }
                                    .tint(.green)
                                    
                                    Button(role: .destructive) {
                                        for issue in group.issues { conversionManager.deletePDF(issue) }
                                    } label: { Label("Delete Series", systemImage: "trash") }
                                }
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
                             .listRowBackground(Theme.bg)
                             .listRowSeparatorTint(Color(UIColor.separator))
                        } else {
                            // ── Cloud files: always open the detail sheet.
                            // Cloud-sourced files cannot be read locally — they need Download & Convert first.
                            if case .cloud = pdf.sourceMode {
                                Button {
                                    onAction(.details, pdf)
                                } label: {
                                    ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                                }
                                .tag(pdf)
                                .listRowBackground(Theme.bg)
                                .listRowSeparatorTint(Color(UIColor.separator))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        isBatchMode = true
                                        multiSelection.insert(pdf.id)
                                    } label: { Label("Select", systemImage: "checkmark.circle.fill") }
                                    .tint(.green)
                                    swipeActionsTrailing(pdf)
                                }
                                .swipeActions(edge: .leading) {
                                    // Leading swipe for cloud = open details (not read)
                                    Button {
                                        onAction(.details, pdf)
                                    } label: { Label("Details", systemImage: "info.circle.fill") }
                                    .tint(Theme.orange)
                                }
                                .contextMenu {
                                    contextMenuContent(pdf)
                                }
                            } else if useNavigationStack && tapAction == .details {
                                // ── Route through onAction \u2014 NavigationLink(value:) removed.
                                // It previously pushed ConvertView, bypassing onAction entirely.
                                Button {
                                    onAction(.details, pdf)
                                } label: {
                                    ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                                }
                                .listRowBackground(Theme.bg)
                                .listRowSeparatorTint(Color(UIColor.separator))
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
                                        onAction(.details, pdf) // using details here to trigger MediaDetailSheet
                                    }
                                } label: {
                                    ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                                }
                                .tag(pdf)
                                .listRowBackground(Theme.bg)
                                .listRowSeparatorTint(Color(UIColor.separator))
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
            } // end List
            .listStyle(.plain)
            .background(Theme.bg)
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
            .id(tapAction)
            } // end ScrollViewReader
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
    
    /// Returns the lowest-progress issue in a series that is not yet finished (< 95% read).
    /// Falls back to the first issue if everything is complete (re-read from start).
    private func nextUnread(in group: SeriesGroup) -> ConvertedPDF? {
        let sorted = group.issues.sorted { a, b in
            let aNum = Int(a.metadata.issueNumber?.filter(\.isNumber) ?? "") ?? 0
            let bNum = Int(b.metadata.issueNumber?.filter(\.isNumber) ?? "") ?? 0
            return aNum < bNum
        }
        return sorted.first {
            (ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0) < 0.95
        } ?? sorted.first
    }

    private func swipeActionsLeading(_ pdf: ConvertedPDF) -> some View {
        // ✅ QoL: leading swipe = read immediately (most common intent)
        Button {
            HapticEngine.success()
            onAction(.read, pdf)
        } label: { Label("Read", systemImage: "play.fill") }
        .tint(Color.inkBlue)
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

        // Cloud files: offer inline convert so the user doesn't need to open the detail sheet
        if case .cloud = pdf.sourceMode {
            let settingsReady = AppSettingsManager.shared.conversionSettings.isConfigured
            Button {
                onAction(.convert, pdf)
            } label: {
                Label(
                    settingsReady ? "Download & Convert" : "Download",
                    systemImage: settingsReady ? "arrow.down.circle.fill" : "arrow.down.circle"
                )
            }
            Divider()
        }
        
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
            onAction(.sendToKindle, pdf)
        } label: { Label("Send to Kindle", systemImage: "k.circle.fill") }
        
        Button {
            onAction(.share, pdf)
        } label: { Label("Share File", systemImage: "square.and.arrow.up") }
        
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
            onAction(.fetchMetadata, pdf)
        } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
    }
}
