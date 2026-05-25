import SwiftUI

import UniformTypeIdentifiers

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
    /// Direct binding to parent's scrollOffset for reliable collapse tracking.
    @Binding var scrollOffset: CGFloat

    // Drop target highlight
    @State private var dropTargetSeriesTitle: String? = nil   // highlights a series row
    @State private var dropTargetPDFID: UUID? = nil           // highlights a single-file row

    // Drop-result confirmation sheet
    @State private var pendingDropInfo: DropResolutionInfo? = nil
    
    var body: some View {
        if conversionManager.visiblePDFs.isEmpty {
            ModernEmptyState(onImport: onImport, onFolderImport: nil)
        } else {
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

                    ForEach(items) { item in
                    switch item {
                    case .series(let group):
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
                            } else {
                                if let folderUUID = UUID(uuidString: group.id) {
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            onFolderTap(folderUUID)
                                        }
                                    } label: {
                                        ModernSeriesRow(group: group, isSelected: false, isBatch: false)
                                    }
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
                    case .single(let pdf):
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
                    case .driveFolder(let entry):
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
                }
            } // end List
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .coordinateSpace(name: "libraryListScroll")
            .onPreferenceChange(LibraryScrollOffsetKey.self) { offset in
                scrollOffset = max(0, offset)
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
        } label: { Label("Edit in Work Area", systemImage: "paintbrush.pointed") }

        // ── Work Area focus pin ─────────────────────────────────────────────
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
