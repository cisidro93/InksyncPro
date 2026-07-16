import SwiftUI
import UniformTypeIdentifiers

// Drag infrastructure moved to LibraryDragDrop.swift


// MARK: - LibraryGridView

struct GridRowItem: Identifiable {
    let id: String
    let items: [LibraryListItem]
}

@MainActor
struct LibraryGridView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.horizontalSizeClass) private var hSizeClass

    let items: [LibraryListItem]
    let contentShelf: ContentShelf
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
    let highlightedItemID: String?

    // Rename series alert state
    @State private var renamingGroup: SeriesGroup? = nil
    @State private var pendingSeriesName: String = ""
    @State private var selectedDetailSeries: SeriesGroup? = nil

    // Drop target highlight
    @State private var dropTargetSeriesTitle: String? = nil   // highlights a series cell
    @State private var dropTargetPDFID: UUID? = nil           // highlights a single-file cell

    // Drop-result confirmation sheet
    @State private var pendingDropInfo: DropResolutionInfo? = nil

    // Drag-to-select Gestures & Coordinate Tracking
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartIndex: Int? = nil
    @State private var currentDragIndex: Int? = nil
    @State private var isDragSelecting: Bool = true
    @State private var initialSelectionBeforeDrag: Set<UUID> = []
    @State private var lastDragLocation: CGPoint = .zero
    @State private var autoScrollTask: Task<Void, Never>? = nil
    @State private var showingQuickJump = false

    private var rows: [GridRowItem] {
        let chunked = chunkedItems(items)
        return chunked.map { chunk in
            let combinedID = chunk.map(\.id).joined(separator: "_")
            return GridRowItem(id: combinedID, items: chunk)
        }
    }

    private var inProgress: [ConvertedPDF] {
        items.compactMap {
            if case .single(let pdf) = $0 {
                let prog = Double(pdf.metadata.lastReadPage ?? 0) / Double(max(pdf.pageCount, 1))
                return (prog > 0.01 && prog < 0.98) ? pdf : nil
            }
            return nil
        }
    }

    private var colCount: Int {
        hSizeClass == .regular ? 5 : 3
    }

    private var colSpacing: CGFloat {
        hSizeClass == .regular ? 16 : 10
    }

    private func chunkedItems(_ source: [LibraryListItem]) -> [[LibraryListItem]] {
        var chunks: [[LibraryListItem]] = []
        var currentChunk: [LibraryListItem] = []
        let limit = colCount
        for item in source {
            currentChunk.append(item)
            if currentChunk.count == limit {
                chunks.append(currentChunk)
                currentChunk = []
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }

    @ViewBuilder
    private func cellFor(_ item: LibraryListItem) -> some View {
        let isHighlighted = item.id == highlightedItemID
        Group {
            switch item {
            case .series(let group):
                seriesCell(group: group)
            case .single(let pdf):
                singleCell(pdf: pdf)
            case .driveFolder(let entry):
                driveFolderCell(entry: entry)
            }
        }
        .scaleEffect(isHighlighted ? 1.04 : 1.0)
        .shadow(color: Color.inkBlue.opacity(isHighlighted ? 0.6 : 0), radius: isHighlighted ? 8 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: item.id.hasPrefix("series") ? 16 : 12, style: .continuous)
                .stroke(Color.inkBlue.opacity(isHighlighted ? 1.0 : 0), lineWidth: 3)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: highlightedItemID)
    }

    private var hPad: CGFloat {
        hSizeClass == .regular ? 16 : 10
    }

    var body: some View {
        Group {
            if conversionManager.visiblePDFs.isEmpty {
                ModernEmptyState(onImport: onImport, onFolderImport: nil)
            } else {
                GeometryReader { viewportGeo in
                    ScrollViewReader { proxy in
                        ZStack {
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
                                if !inProgress.isEmpty {
                                    ContinueReadingShelf(inProgress: Array(inProgress.prefix(10))) { pdf in
                                        if tapAction == .read {
                                            onAction(.read, pdf)
                                        } else {
                                            onAction(.convert, pdf)
                                        }
                                    }
                                    .environmentObject(conversionManager)
                                }



                                let rowItems = rows
                                LazyVStack(spacing: 24) {
                                    ForEach(rowItems) { row in
                                        VStack(spacing: 8) {
                                            HStack(alignment: .bottom, spacing: colSpacing) {
                                                ForEach(row.items) { item in
                                                    cellFor(item)
                                                        .id(item.id)
                                                        .frame(maxWidth: .infinity)
                                                        .background(
                                                            GeometryReader { geo in
                                                                Color.clear
                                                                    .preference(
                                                                        key: LibraryCellFramePreferenceKey.self,
                                                                        value: [item.id: geo.frame(in: .named("libraryScroll"))]
                                                                    )
                                                            }
                                                        )
                                                }
                                                
                                                if row.items.count < colCount {
                                                    ForEach(0..<(colCount - row.items.count), id: \.self) { _ in
                                                        Spacer()
                                                            .frame(maxWidth: .infinity)
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, hPad)
                                            
                                            ShelfLineView(accentColor: contentShelf.accentColor)
                                                .padding(.horizontal, hPad / 2)
                                        }
                                        .id(row.id)
                                    }
                                }
                                .padding(.top, 12)
                                .padding(.bottom, 100)   // overshoots tab bar + home indicator
                            }
                        }
                        .coordinateSpace(name: "libraryScroll")
                        .refreshable {
                            conversionManager.scanLibrary()
                        }
                        .gesture(
                            isBatchMode ?
                            LongPressGesture(minimumDuration: 0.08)
                                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("libraryViewport")))
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
                        .inkTabBarScrollDetect()
                        .background(Color.clear)
                        .overlay(alignment: .trailing) {
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                    showingQuickJump = true
                                }
                                HapticEngine.light()
                            } label: {
                                Image(systemName: "abc")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(.ultraThinMaterial)
                                            .background(Circle().fill(Theme.blue.opacity(0.35)))
                                    )
                                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                            }
                            .padding(.trailing, 8)
                        }
                        .id(tapAction)
                        
                        if showingQuickJump {
                            QuickJumpOverlay(
                                isPresented: $showingQuickJump,
                                availableLetters: availableLetters,
                                onJump: { letter in
                                    if let targetID = firstItemId(for: letter),
                                       let targetRow = rows.first(where: { $0.items.contains(where: { $0.id == targetID }) }) {
                                        withAnimation { proxy.scrollTo(targetRow.id, anchor: .top) }
                                    }
                                }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .zIndex(100)
                        }
                    }
                }
            }
            .coordinateSpace(name: "libraryViewport")
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
                .buttonStyle(TactileButtonStyle())
            } else {
                if UUID(uuidString: group.id) != nil {
                    if useNavigationStack {
                        NavigationLink(value: group) {
                            ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                        }
                        .buttonStyle(TactileButtonStyle())
                    } else {
                        NavigationLink(destination: LazyView { SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack) }) {
                            ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                        }
                        .buttonStyle(TactileButtonStyle())
                    }
                    .contextMenu {
                        Button {
                            selectedDetailSeries = group
                        } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                        
                        Divider()
                        
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
                            if let folderUUID = UUID(uuidString: group.id),
                               let col = conversionManager.collections.first(where: { $0.id == folderUUID }) {
                                conversionManager.deleteCollection(col)
                            }
                        } label: { Label("Delete Folder", systemImage: "trash") }
                    }
                } else {
                    // It's a generated Publisher Series — show the details sheet/stack
                    if useNavigationStack {
                        NavigationLink(value: group) {
                            ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                        }
                        .buttonStyle(TactileButtonStyle())
                    } else {
                        NavigationLink(destination: LazyView { SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: useNavigationStack) }) {
                            ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
                        }
                        .buttonStyle(TactileButtonStyle())
                    }
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
                .buttonStyle(TactileButtonStyle())
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
                    .buttonStyle(TactileButtonStyle())
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
                    .buttonStyle(TactileButtonStyle())
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
        .buttonStyle(TactileButtonStyle())
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
        let getTitle: (LibraryListItem) -> String = { item in
            switch item {
            case .series(let group):      return group.title
            case .single(let pdf):        return pdf.name
            case .driveFolder(let entry): return entry.displayName
            }
        }
        
        if letter == "#" {
            if let firstNumeric = items.first(where: { item in
                let title = getTitle(item)
                guard let firstChar = title.first else { return false }
                return firstChar.isNumber || !firstChar.isLetter
            }) {
                return firstNumeric.id
            }
            return items.first?.id
        }

        // Find the first item starting with this letter
        if let match = items.first(where: { getTitle($0).uppercased().hasPrefix(letter) }) {
            return match.id
        }
        
        // Fallback: find the first item starting with a letter alphabetically greater than the target letter
        if let nextMatch = items.first(where: { getTitle($0).uppercased() > letter }) {
            return nextMatch.id
        }
        
        // Fallback: if no greater letter exists, return the last item in the list
        return items.last?.id
    }

    private var availableLetters: Set<String> {
        let getTitle: (LibraryListItem) -> String = { item in
            switch item {
            case .series(let group):      return group.title
            case .single(let pdf):        return pdf.name
            case .driveFolder(let entry): return entry.displayName
            }
        }
        var lettersSet = Set<String>()
        for item in items {
            let title = getTitle(item)
            if let firstChar = title.first {
                if firstChar.isNumber || !firstChar.isLetter {
                    lettersSet.insert("#")
                } else {
                    lettersSet.insert(String(firstChar).uppercased())
                }
            }
        }
        return lettersSet
    }

    // MARK: - Context Menu

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
        .frame(width: 80, height: 112)
        .shadow(radius: 12)
    }
}

// MARK: - Pan-To-Select Drag Gesture Handlers

extension LibraryGridView {
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
        // Coordinates in cellFrames are in viewport space, so compare directly
        let contentLocation = location
        
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



