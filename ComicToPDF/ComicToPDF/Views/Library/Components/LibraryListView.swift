import SwiftUI

import UniformTypeIdentifiers

@MainActor
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
    let onDropApplied: () -> Void
    @Binding var isScrolledPastHeader: Bool
    let highlightedItemID: String?

    // Drop target highlight
    @State private var dropTargetSeriesTitle: String? = nil   // highlights a series row
    @State private var dropTargetPDFID: UUID? = nil           // highlights a single-file row

    // Drop-result confirmation sheet
    @State private var pendingDropInfo: DropResolutionInfo? = nil
    @State private var selectedDetailSeries: SeriesGroup? = nil

    // Drag-to-select Gestures & Coordinate Tracking
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartIndex: Int? = nil
    @State private var currentDragIndex: Int? = nil
    @State private var isDragSelecting: Bool = true
    @State private var initialSelectionBeforeDrag: Set<UUID> = []
    @State private var lastDragLocation: CGPoint = .zero
    @State private var autoScrollTask: Task<Void, Never>? = nil
    
    private var inProgress: [ConvertedPDF] {
        items.compactMap {
            if case .single(let pdf) = $0 {
                let prog = Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
                return (prog > 0.01 && prog < 0.98) ? pdf : nil
            }
            return nil
        }
    }

    var body: some View {
        // Wrap in Group so .sheet can chain on a concrete view instance.
        // A bare if/else at the top level of body means the trailing .sheet
        // modifier can't find a view instance to attach to (hits View protocol).
        Group {
            if conversionManager.visiblePDFs.isEmpty {
                ModernEmptyState(onImport: onImport, onFolderImport: nil)
            } else {
                GeometryReader { viewportGeo in
                    ScrollViewReader { proxy in
                        List(selection: useNavigationStack ? nil : $selectedPDF) {
                            // ── Scroll offset anchor (zero-height row) ──────────────
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: LibraryScrollOffsetKey.self,
                                        value: -geo.frame(in: .named("libraryListScroll")).minY
                                    )
                            }
                            .frame(height: 0)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())

                            if !inProgress.isEmpty {
                                ContinueReadingShelf(inProgress: Array(inProgress.prefix(10))) { pdf in
                                    if tapAction == .read {
                                        onAction(.read, pdf)
                                    } else {
                                        onAction(.convert, pdf)
                                    }
                                }
                                .environmentObject(conversionManager)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }



                            ForEach(items) { item in
                                listRow(for: item)
                                    .id(item.id)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear
                                                .preference(
                                                    key: LibraryCellFramePreferenceKey.self,
                                                    value: [item.id: geo.frame(in: .named("libraryListScroll"))]
                                                )
                                        }
                                    )
                            }
                        } // end List
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .coordinateSpace(name: "libraryListScroll")
                        .gesture(
                            isBatchMode ?
                            LongPressGesture(minimumDuration: 0.08)
                                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("libraryListViewport")))
                                .onChanged { value in
                                    switch value {
                                    case .first:
                                        break
                                    case .second(_, let dragValue):
                                        if let drag = dragValue {
                                            handleDragUpdate(to: drag.location, viewportHeight: viewportGeo.size.height, scrollProxy: proxy)
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    handleDragEnded()
                                }
                            : nil
                        )
                        .onPreferenceChange(LibraryScrollOffsetKey.self) { offset in
                            self.scrollOffset = offset
                            let past = offset > 44
                            if isScrolledPastHeader != past {
                                isScrolledPastHeader = past
                            }
                        }
                        .onPreferenceChange(LibraryCellFramePreferenceKey.self) { value in
                            self.cellFrames = value
                        }
                        .overlay(alignment: .trailing) {
                            // ✅ PHASE 10: Comic Zeal Feature Restored
                            LibraryIndexScrubber { letter in
                                if let targetID = firstItemId(for: letter) {
                                    withAnimation { proxy.scrollTo(targetID, anchor: .top) }
                                }
                            }
                            .padding(.vertical, 30)
                            .padding(.trailing, 2)
                        }
                        .id(tapAction)
                    } // end ScrollViewReader
                } // end GeometryReader
                .coordinateSpace(name: "libraryListViewport")
            }
        }
        // MARK: Details Sheet
        .sheet(item: $selectedDetailSeries) { group in
            NavigationStack {
                SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: false)
                    .environmentObject(conversionManager)
            }
        }
        // MARK: Drop Resolution Sheet
        .sheet(item: $pendingDropInfo) { info in
            DropResolutionSheet(info: info) { chosenName in
                if !info.allDraggedIssueIDs.isEmpty {
                    applySeriesDrop(
                        issueIDs: info.allDraggedIssueIDs,
                        sourceSeriesName: info.draggedSeriesName,
                        targetSeriesName: chosenName
                    )
                } else {
                    applyDrop(draggedPDFID: info.draggedID, targetSeriesName: chosenName)
                }
            }
        }
    }
    
    // ✅ NEW: Fast Index Search
    private func firstItemId(for letter: String) -> String? {
        if letter == "#" {
            return items.first { item in
                let title: String
                switch item {
                case .series(let group): title = group.title
                case .single(let pdf):  title = pdf.name
                case .driveFolder(let e): title = e.displayName
                }
                guard let firstChar = title.first else { return false }
                return firstChar.isNumber || !firstChar.isLetter
            }?.id
        }
        
        return items.first { item in
            let title: String
            switch item {
            case .series(let group): title = group.title
            case .single(let pdf):  title = pdf.name
            case .driveFolder(let e): title = e.displayName
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
        // ── 1. PRIMARY CONSUMPTION & WORKSPACE ACTIONS ──
        Button { onAction(.read, pdf) } label: { Label("Read / Preview", systemImage: "book.pages") }
        
        let isPinned = WorkspaceFocusManager.shared.isPinned(pdf)
        Button {
            if isPinned {
                WorkspaceFocusManager.shared.unpin(pdf)
            } else {
                WorkspaceFocusManager.shared.pin(pdf)
            }
        } label: {
            Label(
                isPinned ? "Remove from Work Area" : "Send to Work Area",
                systemImage: isPinned ? "pin.slash" : "pin"
            )
        }
        
        Button { onAction(.favorite, pdf) } label: { Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star") }
        
        Divider()
        
        // ── 2. E-READER DIRECT CONVERT & SEND ──
        Button { onAction(.sendToKindle, pdf) } label: { Label("Send to Kindle", systemImage: "k.circle.fill") }
        
        Divider()
        
        // ── 3. GROUPED FUNCTIONAL SUBMENUS ──
        
        // --- MANAGE & ORGANIZE ---
        Menu {
            Button { onAction(.rename, pdf) } label: { Label("Rename", systemImage: "pencil") }
            Button { onAction(.addToSeries, pdf) } label: { Label("Add to Series...", systemImage: "books.vertical") }
            if (pdf.metadata.series?.isEmpty == false) || pdf.collectionId != nil {
                Button { conversionManager.setExplicitSeriesCover(for: pdf) } label: { Label("Set as Series Cover", systemImage: "photo.on.rectangle") }
            }
            
            Divider()
            
            Button {
                ReaderProgressTracker.shared.markComplete(pdfID: pdf.id)
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].metadata.lastReadPage = pdf.pageCount
                    conversionManager.saveProgressOnly()
                }
            } label: { Label("Mark as Read", systemImage: "checkmark.circle") }
            
            Button {
                var progress = ReaderProgressTracker.shared.progress(for: pdf.id) ?? ReadingProgress(pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: 0, totalPagesRead: 0, completionFraction: 0.0, readingSessionDates: [])
                progress.currentPageIndex = 0
                progress.completionFraction = 0.0
                ReaderProgressTracker.shared.update(progress)
                
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].metadata.lastReadPage = 0
                    conversionManager.saveProgressOnly()
                }
            } label: { Label("Mark as Unread", systemImage: "circle") }
            
            Divider()
            
            Button { onAction(.toggleVault, pdf) } label: { Label(pdf.isPrivate ? "Remove from Vault" : "Move to Vault", systemImage: pdf.isPrivate ? "lock.open" : "lock.fill") }
        } label: {
            Label("Manage & Organize", systemImage: "folder.badge.gearshape")
        }
        
        // --- CONVERT & EDIT TOOLS ---
        Menu {
            if case .cloud = pdf.sourceMode {
                // Cloud files download via Cloud & Sync
            } else {
                Button { onAction(.convert, pdf) } label: { Label("Convert File", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button { onAction(.covers, pdf) } label: { Label("Edit in Work Area", systemImage: "paintbrush.pointed") }
            Button { onAction(.editMetadata, pdf) } label: { Label("Edit Metadata & Cover", systemImage: "pencil.and.list.clipboard") }
            Button { onAction(.fetchMetadata, pdf) } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
            Button { Task { await conversionManager.embedPanels(for: pdf) } } label: { Label("Embed Panels", systemImage: "flame") }
        } label: {
            Label("Convert & Edit Tools", systemImage: "slider.horizontal.3")
        }
        
        // --- SYNC & SHARE ---
        Menu {
            if case .cloud = pdf.sourceMode {
                let settingsReady = AppSettingsManager.shared.conversionSettings.isConfigured
                Button { onAction(.convert, pdf) } label: {
                    Label(
                        settingsReady ? "Download & Convert" : "Download",
                        systemImage: settingsReady ? "arrow.down.circle.fill" : "arrow.down.circle"
                    )
                }
            }
            Button { onAction(.sync, pdf) } label: { Label("Direct Cloud Sync", systemImage: "icloud.and.arrow.up") }
            if !AppSettingsManager.shared.linkedDrives.isEmpty {
                Button { onAction(.saveToDrive, pdf) } label: { Label("Save to External Drive…", systemImage: "externaldrive.badge.arrow.down") }
            }
            
            Divider()
            
            Button { onAction(.share, pdf) } label: { Label("Share File", systemImage: "square.and.arrow.up") }
            Button { onAction(.export, pdf) } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        } label: {
            Label("Sync & Share", systemImage: "square.and.arrow.up")
        }
        
        Divider()
        
        // ── 4. DESTRUCTIVE ACTIONS ──
        Button(role: .destructive) { onAction(.delete, pdf) } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Drop Helper Functions

    private func applyDrop(draggedPDFID: UUID, targetSeriesName: String) {
        guard let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == draggedPDFID }) else { return }

        // Set the series name on the dragged file
        conversionManager.convertedPDFs[idx].metadata.series = targetSeriesName

        // Also wire up the collectionId so the LibraryViewModel groups it under
        // the collection-based path (col_) rather than only the series-metadata path.
        if let matchingCollection = conversionManager.collections.first(where: { $0.name == targetSeriesName }) {
            conversionManager.convertedPDFs[idx].collectionId = matchingCollection.id
        } else {
            // Create a new collection so the group tile appears immediately
            conversionManager.createCollection(name: targetSeriesName, icon: "books.vertical", color: "blue")
            if let newCol = conversionManager.collections.first(where: { $0.name == targetSeriesName }) {
                conversionManager.convertedPDFs[idx].collectionId = newCol.id
            }
        }

        conversionManager.saveLibrary()
        HapticEngine.success()
        onDropApplied()
    }

    /// Moves every issue from the dragged series into the destination series,
    /// then removes the now-empty source collection shell.
    private func applySeriesDrop(issueIDs: [UUID], sourceSeriesName: String?, targetSeriesName: String) {
        let destinationCollectionID: UUID
        if let existing = conversionManager.collections.first(where: { $0.name == targetSeriesName }) {
            destinationCollectionID = existing.id
        } else {
            conversionManager.createCollection(name: targetSeriesName, icon: "books.vertical", color: "blue")
            guard let newCol = conversionManager.collections.first(where: { $0.name == targetSeriesName }) else { return }
            destinationCollectionID = newCol.id
        }

        // Re-assign every issue from the dragged series to the destination series
        for id in issueIDs {
            guard let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == id }) else { continue }
            conversionManager.convertedPDFs[idx].metadata.series = targetSeriesName
            conversionManager.convertedPDFs[idx].collectionId = destinationCollectionID
        }

        // Prune the now-empty source collection shell
        if let sourceName = sourceSeriesName,
           !sourceName.isEmpty,
           sourceName != targetSeriesName,
           let sourceCol = conversionManager.collections.first(where: { $0.name == sourceName }) {
            conversionManager.deleteCollection(sourceCol)
        }

        conversionManager.saveLibrary()
        HapticEngine.success()
        onDropApplied()
    }

    // MARK: - Row Sub-views

    @ViewBuilder
    private func listRow(for item: LibraryListItem) -> some View {
        let isHighlighted = item.id == highlightedItemID
        Group {
            switch item {
            case .series(let group):
                seriesRow(group: group)
            case .single(let pdf):
                singleRow(pdf: pdf)
            case .driveFolder(let entry):
                driveFolderRow(entry: entry)
            }
        }
        .scaleEffect(isHighlighted ? 1.02 : 1.0)
        .shadow(color: Color.inkBlue.opacity(isHighlighted ? 0.4 : 0), radius: isHighlighted ? 6 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.inkBlue.opacity(isHighlighted ? 1.0 : 0), lineWidth: 2)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: highlightedItemID)
    }

    @ViewBuilder
    private func seriesRow(group: SeriesGroup) -> some View {
        let isDropTarget = dropTargetSeriesTitle == group.title
        let seriesPayload = LibraryDragPayload(seriesGroup: group)

        Group {
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
                .buttonStyle(TactileButtonStyle())
            } else {
                if let folderUUID = UUID(uuidString: group.id) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            onFolderTap(folderUUID)
                        }
                    } label: {
                        ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(TactileButtonStyle())
                    .contextMenu {
                        Button {
                            selectedDetailSeries = group
                        } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                        
                        Divider()
                        
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
                    NavigationLink(destination: LazyView { SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack) }) {
                        ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(TactileButtonStyle())
                    .contextMenu {
                        Button {
                            selectedDetailSeries = group
                        } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                        
                        Divider()
                        
                        Button {
                            if let next = nextUnread(in: group) {
                                HapticEngine.success()
                                onAction(.read, next)
                            }
                        } label: { Label("Read Next Issue", systemImage: "play.fill") }

                        Divider()
                        
                        let allPinned = group.issues.allSatisfy { WorkspaceFocusManager.shared.isPinned($0) }
                        Button {
                            if allPinned {
                                for issue in group.issues { WorkspaceFocusManager.shared.unpin(issue) }
                            } else {
                                for issue in group.issues { WorkspaceFocusManager.shared.pin(issue) }
                            }
                        } label: {
                            Label(
                                allPinned ? "Remove from Work Area" : "Send Series to Work Area",
                                systemImage: allPinned ? "pin.slash" : "pin"
                            )
                        }

                        Divider()

                        Button {
                            NotificationCenter.default.post(name: Notification.Name("RequestSeriesRename"), object: group)
                        } label: { Label("Rename Series", systemImage: "pencil") }

                        Divider()

                        Button(role: .destructive) {
                            for issue in group.issues { conversionManager.deletePDF(issue) }
                        } label: { Label("Delete Series", systemImage: "trash") }
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
                        } label: { Label("Delete Series", systemImage: "trash") }
                    }
                }
            }
        }
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .listRowSeparatorTint(Color(UIColor.separator))
        .draggable(seriesPayload) {
            ListSeriesDragPreviewRow(group: group)
        }
        .dropDestination(for: LibraryDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            if payload.isSeriesDrag, payload.seriesGroupTitle == group.title { return false }
            if !payload.isSeriesDrag, payload.pdfID == group.issues.first?.id { return false }

            pendingDropInfo = DropResolutionInfo(
                draggedID: payload.pdfID,
                draggedSeriesName: payload.currentSeriesName,
                destinationSeriesName: group.title,
                isFileDroppingOntoSeries: true,
                allDraggedIssueIDs: payload.issueIDs
            )
            dropTargetSeriesTitle = nil
            return true
        } isTargeted: { isOver in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                dropTargetSeriesTitle = isOver ? group.title : nil
            }
        }
        .scaleEffect(isDropTarget ? 0.96 : 1.0)
        .shadow(color: Color.inkBlue.opacity(isDropTarget ? 0.5 : 0), radius: isDropTarget ? 15 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0), value: isDropTarget)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.inkBlue.opacity(isDropTarget ? 0.8 : 0), lineWidth: 2)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
    }

    @ViewBuilder
    private func singleRow(pdf: ConvertedPDF) -> some View {
        let isDropTarget = dropTargetPDFID == pdf.id
        let dragPayload = LibraryDragPayload(pdfID: pdf.id, pdfName: pdf.name, currentSeriesName: pdf.metadata.series)

        Group {
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
                  .buttonStyle(TactileButtonStyle())
             } else {
                 Button {
                     if case .cloud = pdf.sourceMode {
                         if tapAction == .convert {
                             onAction(.convert, pdf)
                         } else {
                             onAction(.details, pdf)
                         }
                     } else {
                         if tapAction == .read {
                             onAction(.read, pdf)
                         } else if tapAction == .convert {
                             onAction(.convert, pdf)
                         } else {
                             onAction(.details, pdf)
                         }
                     }
                 } label: {
                     ModernFileRow(pdf: pdf, isSelected: false, isBatch: false)
                 }
                 .buttonStyle(TactileButtonStyle())
                 .tag(pdf)
                 .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                     Button {
                         isBatchMode = true
                         multiSelection.insert(pdf.id)
                     } label: { Label("Select", systemImage: "checkmark.circle.fill") }
                     .tint(.green)
                     
                     swipeActionsTrailing(pdf)
                 }
                 .swipeActions(edge: .leading) {
                     if case .cloud = pdf.sourceMode {
                         Button {
                             onAction(.details, pdf)
                         } label: { Label("Details", systemImage: "info.circle.fill") }
                         .tint(Theme.orange)
                     } else {
                         swipeActionsLeading(pdf)
                     }
                 }
                 .contextMenu {
                     contextMenuContent(pdf)
                 }
             }
        }
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .listRowSeparatorTint(Color(UIColor.separator))
        .draggable(dragPayload) {
            ListFileDragPreviewRow(pdf: pdf)
        }
        .dropDestination(for: LibraryDragPayload.self) { payloads, _ in
            guard let payload = payloads.first, payload.pdfID != pdf.id else { return false }
            let destinationName: String
            if let draggedName = payload.pdfName {
                destinationName = extractSmartGroupName(str1: draggedName, str2: pdf.name)
            } else {
                destinationName = pdf.metadata.series?.isEmpty == false
                    ? pdf.metadata.series!
                    : pdf.metadata.title
            }
            pendingDropInfo = DropResolutionInfo(
                draggedID: payload.pdfID,
                draggedSeriesName: payload.currentSeriesName,
                destinationSeriesName: destinationName,
                isFileDroppingOntoSeries: false
            )
            dropTargetPDFID = nil
            return true
        } isTargeted: { isOver in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                dropTargetPDFID = isOver ? pdf.id : nil
            }
        }
        .scaleEffect(isDropTarget ? 0.96 : 1.0)
        .shadow(color: Color.inkGreen.opacity(isDropTarget ? 0.5 : 0), radius: isDropTarget ? 15 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0), value: isDropTarget)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.inkGreen.opacity(isDropTarget ? 0.8 : 0), lineWidth: 2)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
    }

    @ViewBuilder
    private func driveFolderRow(entry: AppSettingsManager.LinkedDriveEntry) -> some View {
        let isConnected = DriveMonitor.shared.isConnected(driveID: entry.id)
        NavigationLink(destination:
            LinkedDriveBrowserView(driveEntry: entry)
                .environmentObject(conversionManager)
        ) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.title3)
                    .foregroundStyle(isConnected ? Color(hex: "#6AB0F5") : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text("\(entry.fileCount) files · \(isConnected ? "Connected" : "Disconnected")")
                        .font(.caption)
                        .foregroundStyle(isConnected ? .green : .secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(!isConnected)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .listRowSeparatorTint(Color(UIColor.separator))
        .contextMenu {
            if isConnected {
                Button {
                    Task { await LinkedLibraryScanner.shared.syncDrive(entry) }
                } label: { Label("Sync Drive", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
    }

    // MARK: - Pan-To-Select Drag Gesture Handlers
    
    private func findItemUnderTouch(at location: CGPoint) -> LibraryListItem? {
        for item in items {
            if let frame = cellFrames[item.id], frame.contains(location) {
                return item
            }
        }
        return nil
    }
    
    private func handleDragUpdate(to location: CGPoint, viewportHeight: CGFloat, scrollProxy: ScrollViewProxy) {
        lastDragLocation = location
        let contentLocation = CGPoint(x: location.x, y: location.y + scrollOffset)
        
        if let item = findItemUnderTouch(at: contentLocation) {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                if dragStartIndex == nil {
                    dragStartIndex = index
                    
                    let pdfIDs: [UUID]
                    switch item {
                    case .single(let pdf):
                        pdfIDs = [pdf.id]
                    case .series(let group):
                        pdfIDs = group.issues.map(\.id)
                    case .driveFolder:
                        pdfIDs = []
                    }
                    
                    if let firstID = pdfIDs.first {
                        isDragSelecting = !multiSelection.contains(firstID)
                    } else {
                        isDragSelecting = true
                    }
                    initialSelectionBeforeDrag = multiSelection
                }
                currentDragIndex = index
                updateSelectionForCurrentRange()
            }
        }
        
        let touchViewportY = location.y
        if touchViewportY < 60 || touchViewportY > viewportHeight - 60 {
            if autoScrollTask == nil {
                autoScrollTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        if Task.isCancelled { break }
                        await MainActor.run {
                            performAutoScroll(viewportHeight: viewportHeight, scrollProxy: scrollProxy)
                        }
                    }
                }
            }
        } else {
            autoScrollTask?.cancel()
            autoScrollTask = nil
        }
    }
    
    private func updateSelectionForCurrentRange() {
        guard let startIndex = dragStartIndex, let currentIndex = currentDragIndex else { return }
        let range = min(startIndex, currentIndex)...max(startIndex, currentIndex)
        
        var newSelection = initialSelectionBeforeDrag
        for i in 0..<items.count {
            let item = items[i]
            let isInsideRange = range.contains(i)
            
            let pdfIDs: [UUID]
            switch item {
            case .single(let pdf):
                pdfIDs = [pdf.id]
            case .series(let group):
                pdfIDs = group.issues.map(\.id)
            case .driveFolder:
                pdfIDs = []
            }
            
            for id in pdfIDs {
                if isInsideRange {
                    if isDragSelecting {
                        newSelection.insert(id)
                    } else {
                        newSelection.remove(id)
                    }
                }
            }
        }
        multiSelection = newSelection
    }
    
    private func performAutoScroll(viewportHeight: CGFloat, scrollProxy: ScrollViewProxy) {
        guard let currentIndex = currentDragIndex else { return }
        let touchViewportY = lastDragLocation.y
        
        if touchViewportY < 60 {
            let targetIndex = max(0, currentIndex - 1)
            if targetIndex != currentIndex {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollProxy.scrollTo(items[targetIndex].id, anchor: .top)
                }
                currentDragIndex = targetIndex
                updateSelectionForCurrentRange()
            }
        } else if touchViewportY > viewportHeight - 60 {
            let targetIndex = min(items.count - 1, currentIndex + 1)
            if targetIndex != currentIndex {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollProxy.scrollTo(items[targetIndex].id, anchor: .bottom)
                }
                currentDragIndex = targetIndex
                updateSelectionForCurrentRange()
            }
        }
    }
    
    private func handleDragEnded() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        dragStartIndex = nil
        currentDragIndex = nil
        initialSelectionBeforeDrag.removeAll()
    }
}

// MARK: - Drag Preview Views for List Layout

private struct ListSeriesDragPreviewRow: View {
    let group: SeriesGroup
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.title2)
                .foregroundStyle(Color.inkBlue)
                .frame(width: 40, height: 40)
                .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("\(group.count) issues")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(width: 250)
    }
}

private struct ListFileDragPreviewRow: View {
    let pdf: ConvertedPDF
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(Color.inkGreen)
                .frame(width: 40, height: 40)
                .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(pdf.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(width: 250)
    }
}
