import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag Payload UTType
extension UTType {
    static let libraryDragPayload = UTType(exportedAs: "com.inksyncpro.library.dragpayload")
}

// MARK: - Drag Payload

/// What gets carried when the user drags a library item onto another.
struct LibraryDragPayload: Codable, Transferable {
    let pdfID: UUID
    let currentSeriesName: String?      // nil = ungrouped standalone file

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
                applyDrop(draggedPDFID: info.draggedID, targetSeriesName: chosenName)
            }
        }
    }

    // MARK: - Cell Builders

    @ViewBuilder
    private func seriesCell(group: SeriesGroup) -> some View {
        let isDropTarget = dropTargetSeriesTitle == group.title
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
        // ── Drag: each file in a series can be dragged individually via the single-cell path.
        // ── Drop: series cells accept dropped files/series; smart naming keeps the destination series name.
        .dropDestination(for: LibraryDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            guard payload.pdfID != group.issues.first?.id else { return false } // dropping onto itself
            // Smart rule: destination series name wins unless user explicitly picks otherwise.
            // We still show the sheet so they can confirm or override.
            pendingDropInfo = DropResolutionInfo(
                draggedID: payload.pdfID,
                draggedSeriesName: payload.currentSeriesName,
                destinationSeriesName: group.title,       // ← destination wins by default
                isFileDroppingOntoSeries: true
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
                if useNavigationStack && tapAction == .details {
                    NavigationLink(value: pdf) {
                        ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        contextMenuContent(pdf)
                    } preview: {
                        CoverPreviewCard(pdf: pdf, manager: conversionManager)
                    }
                } else {
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
                        contextMenuContent(pdf)
                    } preview: {
                        CoverPreviewCard(pdf: pdf, manager: conversionManager)
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
        conversionManager.convertedPDFs[idx].metadata.series = targetSeriesName
        conversionManager.saveLibrary()
        HapticEngine.success()
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
        Button { onAction(.covers, pdf) } label: { Label("Edit Workspace (Covers)", systemImage: "paintbrush.pointed") }
        Button { onAction(.favorite, pdf) } label: { Label(pdf.isFavorite ? "Unfavorite" : "Favorite", systemImage: pdf.isFavorite ? "star.slash" : "star") }
        Button { onAction(.export, pdf) } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        Button { onAction(.share, pdf) } label: { Label("Send to Kindle / Share", systemImage: "paperplane") }
        Button { onAction(.sync, pdf) } label: { Label("Direct Cloud Sync", systemImage: "icloud.and.arrow.up") }
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

// MARK: - Drag Preview Card

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

// MARK: - Drop Resolution Info

struct DropResolutionInfo: Identifiable {
    let id = UUID()
    let draggedID: UUID
    let draggedSeriesName: String?
    let destinationSeriesName: String
    let isFileDroppingOntoSeries: Bool  // true = file→series, false = file→file
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

                    Text(info.isFileDroppingOntoSeries ? "Add to Series" : "Create / Merge Series")
                        .font(.title3.bold())
                        .foregroundColor(.primary)

                    Text(info.isFileDroppingOntoSeries
                         ? "Which series name should this issue use?"
                         : "These two files will be grouped. Choose a series name.")
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
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.inkAmber.opacity(0.5), lineWidth: 1))
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(14)
                    .background(Color(UIColor.secondarySystemBackground))
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
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
