import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag Payload UTType
extension UTType {
    /// Use importedAs (not exportedAs) — importedAs works without a
    /// UTExportedTypeDeclarations entry in Info.plist.
    static let libraryDragPayload = UTType(importedAs: "com.inksyncpro.library.dragpayload")
}

// MARK: - Drag Payload

/// What gets carried when the user drags a library item onto another.
/// When `seriesGroupTitle` is non-nil the payload represents an entire series
/// being dragged (series-to-series combine). `pdfID` is set to the cover
/// issue's UUID so `applyDrop` still has a valid UUID anchor, and
/// `issueIDs` carries every issue in the group so they can all be re-assigned.
struct LibraryDragPayload: Codable, Transferable {
    let pdfID: UUID                     // cover issue (or primary file)
    let currentSeriesName: String?      // nil = ungrouped standalone file
    /// Non-nil only when dragging an entire series group.
    let seriesGroupTitle: String?
    /// All issue IDs belonging to the dragged series (empty for single-file drags).
    let issueIDs: [UUID]

    /// Convenience init for single-file drags (preserves backward compat).
    init(pdfID: UUID, currentSeriesName: String?) {
        self.pdfID = pdfID
        self.currentSeriesName = currentSeriesName
        self.seriesGroupTitle = nil
        self.issueIDs = []
    }

    /// Init for dragging an entire series group.
    init(seriesGroup: SeriesGroup) {
        self.pdfID = seriesGroup.coverIssueID ?? seriesGroup.issues.first!.id
        self.currentSeriesName = seriesGroup.title
        self.seriesGroupTitle = seriesGroup.title
        self.issueIDs = seriesGroup.issues.map(\.id)
    }

    var isSeriesDrag: Bool { seriesGroupTitle != nil }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .libraryDragPayload)
    }
}

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
                        let minWidth: CGFloat = hSizeClass == .regular ? 160 : 100
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: 280), spacing: 16)], spacing: 20) {
                            ForEach(items) { item in
                                switch item {
                                case .series(let group):
                                    seriesCell(group: group)
                                case .single(let pdf):
                                    singleCell(pdf: pdf)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 100)
                    }
                    .background(Theme.bg)
                    .overlay(alignment: .trailing) {
                        ComicZealScrubber { letter in
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
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetSeriesTitle = isOver ? group.title : nil
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.inkBlue.opacity(isDropTarget ? 0.9 : 0), lineWidth: 3)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
    }

    @ViewBuilder
    private func singleCell(pdf: ConvertedPDF) -> some View {
        let isDropTarget = dropTargetPDFID == pdf.id
        let dragPayload = LibraryDragPayload(pdfID: pdf.id, currentSeriesName: pdf.metadata.series)

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
                .buttonStyle(PlainButtonStyle())
            } else {
                // ── Cloud files: always open the detail sheet regardless of tapAction.
                // Cloud-sourced files cannot be read locally — they need Download & Convert first.
                if case .cloud = pdf.sourceMode {
                    Button {
                        onAction(.details, pdf)
                    } label: {
                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(PlainButtonStyle())
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
                        } else {
                            onAction(.details, pdf)
                        }
                    } label: {
                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(PlainButtonStyle())
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
            let destinationName = pdf.metadata.series?.isEmpty == false
                ? pdf.metadata.series!
                : pdf.metadata.title    // ungrouped file — use its title as the proposed series name
            pendingDropInfo = DropResolutionInfo(
                draggedID: payload.pdfID,
                draggedSeriesName: payload.currentSeriesName,
                destinationSeriesName: destinationName,
                isFileDroppingOntoSeries: false
            )
            dropTargetPDFID = nil
            return true
        } isTargeted: { isOver in
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetPDFID = isOver ? pdf.id : nil
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.inkGreen.opacity(isDropTarget ? 0.9 : 0), lineWidth: 3)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
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

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuContent(_ pdf: ConvertedPDF) -> some View {
        Button { onAction(.read, pdf) } label: { Label("Read / Preview", systemImage: "book.pages") }

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

// MARK: - Drop Resolution Info

struct DropResolutionInfo: Identifiable {
    let id = UUID()
    let draggedID: UUID
    let draggedSeriesName: String?
    let destinationSeriesName: String
    let isFileDroppingOntoSeries: Bool  // true = file→series or series→series, false = file→file
    /// Non-empty when dragging an entire series (series→series combine).
    let allDraggedIssueIDs: [UUID]

    init(
        draggedID: UUID,
        draggedSeriesName: String?,
        destinationSeriesName: String,
        isFileDroppingOntoSeries: Bool,
        allDraggedIssueIDs: [UUID] = []
    ) {
        self.draggedID = draggedID
        self.draggedSeriesName = draggedSeriesName
        self.destinationSeriesName = destinationSeriesName
        self.isFileDroppingOntoSeries = isFileDroppingOntoSeries
        self.allDraggedIssueIDs = allDraggedIssueIDs
    }
}

// MARK: - Drop Resolution Sheet

struct DropResolutionSheet: View {
    let info: DropResolutionInfo
    let onConfirm: (String) -> Void

    @State private var customName: String = ""
    @State private var useCustomName = false
    @Environment(\.dismiss) private var dismiss

    private var smartDefault: String { info.destinationSeriesName }
    private var hasAlternative: Bool {
        let dName = info.draggedSeriesName ?? ""
        return !dName.isEmpty && dName != info.destinationSeriesName
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Icon + headline
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.inkBlue.opacity(0.15))
                            .frame(width: 80, height: 80)
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.inkBlue.gradient)
                    }
                    .padding(.top, 32)

                    Text(info.allDraggedIssueIDs.isEmpty
                         ? (info.isFileDroppingOntoSeries ? "Add to Series" : "Create / Merge Series")
                         : "Combine Series")
                        .font(.title3.bold())
                        .foregroundColor(.primary)

                    Text(info.allDraggedIssueIDs.isEmpty
                         ? (info.isFileDroppingOntoSeries
                            ? "Which series name should this issue use?"
                            : "These two files will be grouped. Choose a series name.")
                         : "\(info.allDraggedIssueIDs.count) issue\(info.allDraggedIssueIDs.count == 1 ? "" : "s") from \"\(info.draggedSeriesName ?? "source")\" will move into this series. Which name should they use?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 28)

                // Options
                VStack(spacing: 10) {
                    // Smart default: destination name
                    OptionRow(
                        label: "Keep destination series name",
                        value: info.destinationSeriesName,
                        isSelected: !useCustomName,
                        accent: .inkBlue
                    ) {
                        useCustomName = false
                    }

                    // Alternative: dragged item's series name (only shown if different)
                    if hasAlternative, let altName = info.draggedSeriesName {
                        OptionRow(
                            label: "Use dragged item's series name",
                            value: altName,
                            isSelected: false,
                            accent: .inkViolet
                        ) {
                            useCustomName = true
                            customName = altName
                        }
                    }

                    // Custom name input
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "pencil")
                                .foregroundColor(useCustomName ? .inkAmber : .secondary)
                            Text("Use a custom name")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(useCustomName ? .inkAmber : .secondary)
                            Spacer()
                            if useCustomName {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.inkAmber)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { useCustomName = true }

                        if useCustomName {
                            TextField("Series name…", text: $customName)
                                .padding(12)
                                .background(Color.inkSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.inkAmber.opacity(0.5), lineWidth: 1))
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(14)
                    .background(Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 20)

                Spacer()

                // Confirm button
                Button {
                    let resolved = useCustomName
                        ? customName.trimmingCharacters(in: .whitespacesAndNewlines)
                        : smartDefault
                    guard !resolved.isEmpty else { return }
                    onConfirm(resolved)
                    dismiss()
                } label: {
                    Text("Confirm")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.inkBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .disabled(useCustomName && customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Option Row

private struct OptionRow: View {
    let label: String
    let value: String
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? accent : .secondary)
                .font(.system(size: 22))
        }
        .padding(14)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
