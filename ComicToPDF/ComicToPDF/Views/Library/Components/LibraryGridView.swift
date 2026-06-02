import SwiftUI
import UniformTypeIdentifiers

// Drag infrastructure moved to LibraryDragDrop.swift


// MARK: - LibraryGridView

struct LibraryGridView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass

    let items: [LibraryListItem]
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    let useNavigationStack: Bool
    @Binding var tapAction: LibraryTapAction
    @Binding var selectedPDF: ConvertedPDF?

    let onAction: (LibraryRowAction, ConvertedPDF) -> Void
    let onImport: () -> Void
    let onFolderTap: (UUID?) -> Void
    /// Called immediately after any drop merge is committed so the parent
    /// can force-rebuild the cache from live in-memory data without waiting
    /// for the SwiftData @Query async refresh cycle.
    let onDropApplied: () -> Void
    @Binding var isScrolledPastHeader: Bool

    // Rename series alert state
    @State private var renamingGroup: SeriesGroup? = nil
    @State private var pendingSeriesName: String = ""

    // Drop target highlight
    @State private var dropTargetSeriesTitle: String? = nil   // highlights a series cell
    @State private var dropTargetPDFID: UUID? = nil           // highlights a single-file cell

    // Drop-result confirmation sheet
    @State private var pendingDropInfo: DropResolutionInfo? = nil

    var body: some View {
        Group {
            if conversionManager.visiblePDFs.isEmpty {
                ModernEmptyState(onImport: onImport, onFolderImport: nil)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            // ── Scroll offset anchor ─────────────────────────
                            // A zero-height GeometryReader pinned at the very top of
                            // the scroll content. Its minY in the named coordinate
                            // space equals how far the user has scrolled down (positive).
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: LibraryScrollOffsetKey.self,
                                        value: -geo.frame(in: .named("libraryScroll")).minY
                                    )
                            }
                            .frame(height: 0)

                            // ── Continue Reading shelf ─────────────────────
                            let inProgress: [ConvertedPDF] = items.compactMap {
                                if case .single(let pdf) = $0 {
                                    let prog = Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
                                    return (prog > 0.01 && prog < 0.98) ? pdf : nil
                                }
                                return nil
                            }
                            if !inProgress.isEmpty {
                                ContinueReadingShelf(inProgress: Array(inProgress.prefix(10))) { pdf in
                                    if tapAction == .read {
                                        onAction(.read, pdf)
                                    } else {
                                        onAction(.convert, pdf)
                                    }
                                }
                                .environmentObject(conversionManager)
                                Divider().background(Theme.text.opacity(0.06)).padding(.horizontal, 16)
                            }

                            // Recently Added banner removed to declutter workspace

                            // ── Main grid ─────────────────────────────────
                            let hPad: CGFloat = hSizeClass == .regular ? 20 : 16
                            let colSpacing: CGFloat = hSizeClass == .regular ? 20 : 14
                            // Fixed 3-column on iPad, 2-column on iPhone — guarantees every
                            // thumbnail gets an identical column width (uniform sizes, no overlap).
                            let colCount = hSizeClass == .regular ? 3 : 2
                            let columns = Array(repeating: GridItem(.flexible(), spacing: colSpacing), count: colCount)
                            LazyVGrid(
                                columns: columns,
                                spacing: hSizeClass == .regular ? 24 : 18
                            ) {
                                ForEach(items) { item in
                                    switch item {
                                    case .series(let group):
                                        seriesCell(group: group)
                                    case .single(let pdf):
                                        singleCell(pdf: pdf)
                                    case .driveFolder(let entry):
                                        driveFolderCell(entry: entry)
                                    }
                                }
                            }
                            .padding(.horizontal, hPad)
                            .padding(.top, 12)
                            .padding(.bottom, 120)   // overshoots tab bar + home indicator
                        }
                    }
                    .coordinateSpace(name: "libraryScroll")
                    .onPreferenceChange(LibraryScrollOffsetKey.self) { offset in
                        let past = offset > 44
                        if isScrolledPastHeader != past {
                            isScrolledPastHeader = past
                        }
                    }
                    .inkTabBarScrollDetect()
                    .background(Color.clear)
                    .overlay(alignment: .trailing) {
                        LibraryIndexScrubber { letter in
                            if let targetID = firstItemId(for: letter) {
                                withAnimation { proxy.scrollTo(targetID, anchor: .top) }
                            }
                        }
                        .padding(.vertical, 30)
                        .padding(.trailing, 2)
                    }
                    .id(tapAction)
                }
            }
        }
        // MARK: Rename Alert
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
                
                if let folderUUID = UUID(uuidString: group.id),
                   let colIdx = conversionManager.collections.firstIndex(where: { $0.id == folderUUID }) {
                    conversionManager.collections[colIdx].name = newName
                }
                
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
        // MARK: Drop Resolution Sheet
        .sheet(item: $pendingDropInfo) { info in
            DropResolutionSheet(info: info) { chosenName in
                if !info.allDraggedIssueIDs.isEmpty {
                    // Series-to-series combine: move every issue from source series
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

    // MARK: - Cell Builders

    @ViewBuilder
    private func seriesCell(group: SeriesGroup) -> some View {
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
                    ModernGridSeriesCell(group: group, isSelected: group.issues.allSatisfy { multiSelection.contains($0.id) }, isBatch: true)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                if let folderUUID = UUID(uuidString: group.id) {
                    // It's a custom Collection folder — drill down natively
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            onFolderTap(folderUUID)
                        }
                    } label: {
                        ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        // Standard Series context actions...
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
                                allPinned ? "Remove from Work Area" : "Send Folder to Work Area",
                                systemImage: allPinned ? "pin.slash" : "pin"
                            )
                        }
                        
                        Divider()
                        Button {
                            pendingSeriesName = group.title
                            renamingGroup = group
                        } label: { Label("Rename Folder", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) {
                            for issue in group.issues { conversionManager.deletePDF(issue) }
                        } label: { Label("Delete Folder", systemImage: "trash") }
                    }
                } else {
                    // It's a generated Publisher Series — show the details sheet/stack
                    NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack)) {
                        ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
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
                            pendingSeriesName = group.title
                            renamingGroup = group
                        } label: { Label("Rename Series", systemImage: "pencil") }

                        Divider()

                        Button(role: .destructive) {
                            for issue in group.issues { conversionManager.deletePDF(issue) }
                        } label: { Label("Delete Series", systemImage: "trash") }
                    }
                }
            }
        }
        // ── Drag: series cards are draggable — lifting a series lets you combine it with another.
        .draggable(seriesPayload) {
            SeriesDragPreviewCard(group: group, manager: conversionManager)
        }
        // ── Drop: series cells accept dropped single files AND dropped series.
        // Smart rule: destination series name wins. Sheet lets user override.
        .dropDestination(for: LibraryDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            // Prevent dropping a series onto itself
            if payload.isSeriesDrag, payload.seriesGroupTitle == group.title { return false }
            if !payload.isSeriesDrag, payload.pdfID == group.issues.first?.id { return false }

            // Destination name always wins (smart default)
            pendingDropInfo = DropResolutionInfo(
                draggedID: payload.pdfID,
                draggedSeriesName: payload.currentSeriesName,
                destinationSeriesName: group.title,
                isFileDroppingOntoSeries: true,
                // Pass along all issue IDs so applyDrop can move the whole series
                allDraggedIssueIDs: payload.issueIDs
            )
            dropTargetSeriesTitle = nil
            return true
        } isTargeted: { isOver in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                dropTargetSeriesTitle = isOver ? group.title : nil
            }
        }
        .scaleEffect(isDropTarget ? 0.93 : 1.0)
        .shadow(color: Color.inkBlue.opacity(isDropTarget ? 0.5 : 0), radius: isDropTarget ? 15 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0), value: isDropTarget)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.inkBlue.opacity(isDropTarget ? 0.9 : 0), lineWidth: 3)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
    }

    @ViewBuilder
    private func singleCell(pdf: ConvertedPDF) -> some View {
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
                    ModernGridFileCell(pdf: pdf, isSelected: multiSelection.contains(pdf.id), isBatch: true)
                }
                .buttonStyle(CellButtonStyle())
            } else {
                // ── Cloud files: always open the detail sheet regardless of tapAction.
                // Cloud-sourced files cannot be read locally — they need Download & Convert first.
                if case .cloud = pdf.sourceMode {
                    Button {
                        if tapAction == .convert {
                            onAction(.convert, pdf)
                        } else {
                            onAction(.details, pdf)
                        }
                    } label: {
                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(CellButtonStyle())
                    .contextMenu {
                        if hSizeClass == .compact {
                            Button {
                                let destinationName = pdf.metadata.series?.isEmpty == false
                                    ? pdf.metadata.series!
                                    : pdf.metadata.title
                                pendingDropInfo = DropResolutionInfo(
                                    draggedID: pdf.id,
                                    draggedSeriesName: pdf.metadata.series,
                                    destinationSeriesName: destinationName,
                                    isFileDroppingOntoSeries: false
                                )
                            } label: { Label("Move to Series…", systemImage: "folder.badge.plus") }
                            Divider()
                        }
                        contextMenuContent(pdf)
                    }
                } else {
                    // ── Local/Linked files: always route through onAction so LibraryViewModel
                    // can open the correct fullScreenCover (read) or sheet (details).
                    // NavigationLink(value:) was removed — it routed to ConvertView which
                    // is not the intended destination for a library tap.
                    Button {
                        if tapAction == .read {
                            onAction(.read, pdf)
                        } else if tapAction == .convert {
                            onAction(.convert, pdf)
                        } else {
                            onAction(.details, pdf)
                        }
                    } label: {
                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(CellButtonStyle())
                    .contextMenu {
                        if hSizeClass == .compact {
                            Button {
                                let destinationName = pdf.metadata.series?.isEmpty == false
                                    ? pdf.metadata.series!
                                    : pdf.metadata.title
                                pendingDropInfo = DropResolutionInfo(
                                    draggedID: pdf.id,
                                    draggedSeriesName: pdf.metadata.series,
                                    destinationSeriesName: destinationName,
                                    isFileDroppingOntoSeries: false
                                )
                            } label: { Label("Move to Series…", systemImage: "folder.badge.plus") }
                            Divider()
                        }
                        contextMenuContent(pdf)
                    } preview: {
                        if hSizeClass == .regular {
                            CoverPreviewCard(pdf: pdf, manager: conversionManager)
                        } else {
                            EmptyView()
                        }
                    }
                }
            }
        }
        // ── Drag: make each individual file draggable
        .draggable(dragPayload) {
            // Drag preview: small cover thumbnail or generic icon
            DragPreviewCard(pdf: pdf, manager: conversionManager)
        }
        // ── Drop: file-onto-file creates a new series.
        // Smart rule: when dragging file A onto file B, keep B's series name (or B's title if ungrouped).
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
        .scaleEffect(isDropTarget ? 0.93 : 1.0)
        .shadow(color: Color.inkGreen.opacity(isDropTarget ? 0.5 : 0), radius: isDropTarget ? 15 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0), value: isDropTarget)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.inkGreen.opacity(isDropTarget ? 0.9 : 0), lineWidth: 3)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
    }

    // MARK: - Drive Folder Cell

    @ViewBuilder
    private func driveFolderCell(entry: AppSettingsManager.LinkedDriveEntry) -> some View {
        let isConnected = DriveMonitor.shared.isConnected(driveID: entry.id)
        NavigationLink(destination: LinkedDriveBrowserView(driveEntry: entry)) {
            ZStack(alignment: .bottomLeading) {
                // Card background
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(hex: isConnected ? "#1C2E4A" : "#2A2A2A"),
                            Color(hex: isConnected ? "#0F1B2E" : "#1A1A1A")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .aspectRatio(2/3, contentMode: .fit)

                // Drive icon watermark
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.white.opacity(0.06))
                    .offset(x: -8, y: 8)

                // Info overlay
                VStack(alignment: .leading, spacing: 4) {
                    // Connection pill
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isConnected ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(isConnected ? "Connected" : "Disconnected")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isConnected ? Color.green : Color.orange)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    // Name + count
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text("\(entry.fileCount) files · Browse")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(12)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isConnected)
        .opacity(isConnected ? 1.0 : 0.55)
        .contextMenu {
            if isConnected {
                Button {
                    Task { await LinkedLibraryScanner.shared.syncDrive(entry) }
                } label: { Label("Sync Drive", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button {
                AppRouter.shared.presentSheet(.cloudBrowser)
            } label: { Label("Manage in Settings", systemImage: "gear") }
        }
    }

    // MARK: - Helpers

    /// Next unread issue in a series — lowest-numbered issue below 95% completion.
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
    /// The destination series name always wins (smart default — user confirmed via sheet).
    private func applySeriesDrop(issueIDs: [UUID], sourceSeriesName: String?, targetSeriesName: String) {
        // Resolve or create the destination collection up-front so all re-assignments
        // can reference the same collectionId atomically.
        let destinationCollectionID: UUID
        if let existing = conversionManager.collections.first(where: { $0.name == targetSeriesName }) {
            destinationCollectionID = existing.id
        } else {
            conversionManager.createCollection(name: targetSeriesName, icon: "books.vertical", color: "blue")
            // Safe optional — if createCollection fails silently we bail rather than crashing.
            guard let newCol = conversionManager.collections.first(where: { $0.name == targetSeriesName }) else { return }
            destinationCollectionID = newCol.id
        }

        // Re-assign every issue from the dragged series to the destination series
        for id in issueIDs {
            guard let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == id }) else { continue }
            conversionManager.convertedPDFs[idx].metadata.series = targetSeriesName
            conversionManager.convertedPDFs[idx].collectionId = destinationCollectionID
        }

        // Prune the now-empty source collection shell so it doesn't ghost in the grid
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

    // MARK: - Index Scrubber helper

    private func firstItemId(for letter: String) -> String? {
        if letter == "#" {
            return items.first { item in
                let title: String
                switch item {
                case .series(let group):      title = group.title
                case .single(let pdf):        title = pdf.name
                case .driveFolder(let entry): title = entry.displayName
                }
                guard let firstChar = title.first else { return false }
                return firstChar.isNumber || !firstChar.isLetter
            }?.id
        }

        return items.first { item in
            let title: String
            switch item {
            case .series(let group):      title = group.title
            case .single(let pdf):        title = pdf.name
            case .driveFolder(let entry): title = entry.displayName
            }
            return title.uppercased().hasPrefix(letter)
        }?.id
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuContent(_ pdf: ConvertedPDF) -> some View {
        Button { onAction(.read, pdf) } label: { Label("Read / Preview", systemImage: "book.pages") }

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

        // Cloud files: offer inline convert so the user doesn't need to open the detail sheet
        if case .cloud = pdf.sourceMode {
            let settingsReady = AppSettingsManager.shared.conversionSettings.isConfigured
            Button { onAction(.convert, pdf) } label: {
                Label(
                    settingsReady ? "Download & Convert" : "Download",
                    systemImage: settingsReady ? "arrow.down.circle.fill" : "arrow.down.circle"
                )
            }
            Divider()
        }
        Button { onAction(.covers, pdf) } label: { Label("Edit in Work Area", systemImage: "paintbrush.pointed") }

        // ── Work Area focus pin ──────────────────────────────────────────────
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
        Button { onAction(.export, pdf) } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        Button { onAction(.sendToKindle, pdf) } label: { Label("Send to Kindle", systemImage: "k.circle.fill") }
        Button { onAction(.share, pdf) } label: { Label("Share File", systemImage: "square.and.arrow.up") }
        Button { onAction(.sync, pdf) } label: { Label("Direct Cloud Sync", systemImage: "icloud.and.arrow.up") }

        // Show "Save to Drive" only when there is at least one linked drive configured
        if !AppSettingsManager.shared.linkedDrives.isEmpty {
            Button { onAction(.saveToDrive, pdf) } label: { Label("Save to External Drive…", systemImage: "externaldrive.badge.arrow.down") }
        }

        Button { onAction(.rename, pdf) } label: { Label("Rename", systemImage: "pencil") }
        Button { onAction(.addToSeries, pdf) } label: { Label("Add to Series...", systemImage: "books.vertical") }

        if (pdf.metadata.series != nil && !pdf.metadata.series!.isEmpty) || pdf.collectionId != nil {
            Button { conversionManager.setExplicitSeriesCover(for: pdf) } label: { Label("Set as Series Cover", systemImage: "photo.on.rectangle") }
        }

        Button { Task { await conversionManager.embedPanels(for: pdf) } } label: { Label("Embed Panels", systemImage: "flame") }
        Button(role: .destructive) { onAction(.delete, pdf) } label: { Label("Delete", systemImage: "trash") }
        Divider()
        Button { onAction(.toggleVault, pdf) } label: { Label(pdf.isPrivate ? "Remove from Vault" : "Move to Vault", systemImage: pdf.isPrivate ? "lock.open" : "lock.fill") }
        Button { onAction(.editMetadata, pdf) } label: { Label("Edit Metadata & Cover", systemImage: "pencil.and.list.clipboard") }
        Button { onAction(.fetchMetadata, pdf) } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
    }
}

// MARK: - Drag Preview Cards

private struct DragPreviewCard: View {
    let pdf: ConvertedPDF
    let manager: ConversionManager

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)

            if let img = manager.getThumbnail(for: pdf) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 112)
        .shadow(radius: 12)
    }
}

/// Drag preview shown when lifting an entire series — two stacked covers + a count badge.
private struct SeriesDragPreviewCard: View {
    let group: SeriesGroup
    let manager: ConversionManager

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Second cover peeking behind
            if let secondID = group.issues.dropFirst().first?.id,
               let img = manager.thumbnailCache.object(forKey: secondID.uuidString as NSString) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 72, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .rotationEffect(.degrees(-6))
                    .offset(x: -6, y: 6)
                    .opacity(0.7)
            }

            // Front cover
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial)
                if let coverID = group.coverIssueID,
                   let img = manager.thumbnailCache.object(forKey: coverID.uuidString as NSString) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 112)

            // Issue count badge
            Text("\(group.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.inkBlue)
                .clipShape(Capsule())
                .offset(x: 4, y: 4)
        }
        .shadow(radius: 14)
    }
}



