import SwiftUI
import UniformTypeIdentifiers
import Combine

/// Unified, high-performance volume creator and editor for comic and manga files.
/// Consolidates non-destructive Virtual Volumes (instant continuous reading, 0MB disk space, remote CBL sync)
/// and Standalone Physical Archives (CBZ/EPUB/PDF merge) into a single cohesive interface.
/// Includes recurring volume pattern recognition, range selection, and next-issue auto-suggestions.
struct VolumeStudioView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager

    enum VolumeType: String, CaseIterable, Identifiable {
        case virtual = "Digital Atelier Binder"
        case assign = "Assign Volume"
        case physicalMerge = "Standalone Archive"

        var id: String { rawValue }
        var tabTitle: String {
            switch self {
            case .virtual: return "Atelier Binder"
            case .assign: return "Assign Vol"
            case .physicalMerge: return "Standalone"
            }
        }
        var icon: String {
            switch self {
            case .virtual: return "book.closed.fill"
            case .assign: return "folder.badge.plus"
            case .physicalMerge: return "archivebox.fill"
            }
        }
        var shortDescription: String {
            switch self {
            case .virtual: return "0 MB virtual cloth-bound volume. Instant continuous reading & CBL sync without duplicating files."
            case .assign: return "Tags files with a volume number to organize them into series shelves."
            case .physicalMerge: return "Merged single-file CBZ, EPUB, or PDF for external export."
            }
        }
    }

    // Context & Pre-population
    let existingOmnibus: VirtualOmnibus?
    let parentSeriesID: String?
    let initialMode: VolumeType

    // Core Volume State
    @State private var volumeType: VolumeType
    @State private var volumeName: String
    @State private var selectedFiles: [ConvertedPDF] = []
    @State private var fileIDs: [UUID] = []
    @State private var remoteSyncURL: String = ""
    @State private var tagIssuesWithVolumeName: Bool = true

    // Standalone Physical Archive Settings
    @State private var standaloneOutputFormat: OutputFormat = .cbz
    @State private var mangaMode: Bool = false
    @State private var deleteSourceFilesAfterMerge: Bool = false
    @State private var isProcessingMerge: Bool = false
    @State private var includeTOC: Bool = true
    @State private var tocTitlePreset: ChapterTitleSanitizer.TitleFormatPreset = .smartClean
    @State private var customChapterTitles: [UUID: String] = [:]

    // Pattern Recognition & Smart Suggestions
    @State private var patternSuggestedIssues: [ConvertedPDF] = []
    @State private var patternSuggestedVolumeNumber: Int = 0
    @State private var showPatternBanner: Bool = false
    @State private var dismissedPatternSuggestion: Bool = false

    // Range Selection State
    @State private var rangeStart: String = ""
    @State private var rangeEnd: String = ""

    // Search & Library Recommendations
    @State private var searchQuery: String = ""
    @State private var smartSuggestions: [ConvertedPDF] = []
    @State private var isSearchFocused: Bool = false

    init(
        existingOmnibus: VirtualOmnibus? = nil,
        initialFileIDs: [UUID] = [],
        suggestedName: String = "",
        parentSeriesID: String? = nil,
        initialMode: VolumeType = .virtual
    ) {
        self.existingOmnibus = existingOmnibus
        self.parentSeriesID = existingOmnibus?.parentSeriesID ?? parentSeriesID
        self.initialMode = existingOmnibus != nil ? .virtual : initialMode

        _volumeType = State(initialValue: existingOmnibus != nil ? .virtual : initialMode)
        _volumeName = State(initialValue: existingOmnibus?.name ?? suggestedName)
        _remoteSyncURL = State(initialValue: existingOmnibus?.remoteSyncURL ?? "")
        
        var resolvedIDs = existingOmnibus?.fileIDs ?? initialFileIDs
        if existingOmnibus == nil && !resolvedIDs.isEmpty {
            let all = ConversionManager.shared.visiblePDFs
            let matching = resolvedIDs.compactMap { id in all.first(where: { $0.id == id }) }
            if matching.count == resolvedIDs.count {
                resolvedIDs = matching.sorted(by: ConvertedPDF.naturalIssueSort).map(\.id)
            }
        }
        _fileIDs = State(initialValue: resolvedIDs)
        _standaloneOutputFormat = State(initialValue: AppSettingsManager.shared.conversionSettings.outputFormat)
    }

    init(
        initialFiles: [ConvertedPDF],
        suggestedName: String = "",
        parentSeriesID: String? = nil,
        initialMode: VolumeType = .virtual
    ) {
        let sorted = initialFiles.sorted(by: ConvertedPDF.naturalIssueSort)
        self.init(
            existingOmnibus: nil,
            initialFileIDs: sorted.map(\.id),
            suggestedName: suggestedName,
            parentSeriesID: parentSeriesID,
            initialMode: initialMode
        )
    }

    // MARK: - Computed Properties

    private var seriesContextTitle: String {
        if let parent = parentSeriesID, !parent.isEmpty {
            // Check if parent is a collection name or UUID
            if let colUUID = UUID(uuidString: parent),
               let col = conversionManager.collections.first(where: { $0.id == colUUID }) {
                return col.name
            }
            return parent
        }
        if let firstSeries = selectedFiles.first?.metadata.series, !firstSeries.isEmpty {
            return firstSeries
        }
        return "Series"
    }

    /// All issues in the active series context for pattern analysis and smart selection
    private var seriesPoolFiles: [ConvertedPDF] {
        let allVisible = conversionManager.visiblePDFs
        if let parent = parentSeriesID, !parent.isEmpty {
            if let folderUUID = UUID(uuidString: parent) {
                return allVisible.filter { $0.collectionId == folderUUID }
            }
            return allVisible.filter { pdf in
                pdf.metadata.series?.localizedCaseInsensitiveCompare(parent) == .orderedSame ||
                pdf.name.localizedCaseInsensitiveContains(parent)
            }
        }
        if let firstSeries = selectedFiles.first?.metadata.series, !firstSeries.isEmpty {
            return allVisible.filter {
                $0.metadata.series?.localizedCaseInsensitiveCompare(firstSeries) == .orderedSame
            }
        }
        return allVisible
    }

    /// Search results from the entire visible library excluding already added files
    private var searchResults: [ConvertedPDF] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSet = Set(fileIDs)

        return conversionManager.visiblePDFs.filter { pdf in
            guard !selectedSet.contains(pdf.id) else { return false }
            return matchesSearchQuery(name: pdf.name, query: query) ||
                   (pdf.metadata.series?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    /// Next logical issue auto-suggestion based on the last issue in the volume sequence
    private var nextSuggestedIssue: ConvertedPDF? {
        guard let lastFile = selectedFiles.last else { return nil }
        let currentNum = lastFile.resolvedIssueNumber
        guard let num = currentNum else { return nil }
        let targetNum = num + 1.0

        let selectedSet = Set(fileIDs)
        return seriesPoolFiles.first { pdf in
            guard !selectedSet.contains(pdf.id) else { return false }
            if let n = pdf.resolvedIssueNumber, abs(n - targetNum) < 0.01 {
                return true
            }
            return false
        }
    }

    private var totalPages: Int {
        selectedFiles.reduce(0) { $0 + max($1.pageCount, 1) }
    }

    private var totalSizeFormatted: String {
        let bytes = selectedFiles.reduce(Int64(0)) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var isSaveDisabled: Bool {
        if selectedFiles.isEmpty || isProcessingMerge {
            return true
        }
        if volumeType == .assign {
            return false
        }
        return volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - View Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                if isProcessingMerge {
                    ImmersiveConversionOverlay(
                        pdfName: volumeName.isEmpty ? "Merged Volume" : volumeName,
                        customMessage: conversionManager.statusMessage ?? "Compiling Volume..."
                    )
                } else {
                    mainEditorContent
                }
            }
            .navigationTitle(existingOmnibus == nil ? "Create Volume" : "Edit Volume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        HapticEngine.selection()
                        dismiss()
                    }
                    .foregroundColor(.inkTextSecondary)
                    .disabled(isProcessingMerge)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(actionButtonTitle) {
                        handlePrimaryAction()
                    }
                    .font(.system(.body, design: .rounded).bold())
                    .foregroundColor(isSaveDisabled ? .inkTextTertiary : .inkBlue)
                    .disabled(isSaveDisabled)
                }
            }
            .onAppear {
                reloadInitialFiles()
                checkForVolumePatterns()
                updateSmartSuggestions()
            }
            .onChange(of: conversionManager.visiblePDFs) { _, newFiles in
                // Keep selected file instances refreshed if underlying metadata changed
                selectedFiles = fileIDs.compactMap { id in newFiles.first(where: { $0.id == id }) }
                updateSmartSuggestions()
            }
            .onChange(of: volumeName) { _, _ in
                updateSmartSuggestions()
            }
        }
    }

    private var actionButtonTitle: String {
        if existingOmnibus != nil {
            return "Save Changes"
        }
        switch volumeType {
        case .virtual: return "Bind Virtual Volume (0 MB)"
        case .assign:
            let trimmed = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Clear Volume Grouping" : "Assign Volume \(trimmed)"
        case .physicalMerge: return "Convert & Merge"
        }
    }

    // MARK: - Main Editor Layout

    private var mainEditorContent: some View {
        VStack(spacing: 0) {
            // Segmented Volume Type Switcher (only for new volumes)
            if existingOmnibus == nil {
                volumeTypeSwitcher
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            // Pattern Recognition Suggestion Banner
            if showPatternBanner && !dismissedPatternSuggestion {
                patternSuggestionBanner
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            List {
                // Section 1: Volume Details & Configuration
                volumeConfigurationSection

                // Section 2: Smart Tools (Range Selector & Next-Issue Suggestion)
                smartToolsSection

                // Section 3: Smart Recommendations (Levenshtein matches)
                if !smartSuggestions.isEmpty {
                    smartSuggestionsSection
                }

                // Section 4: Included Issues (120Hz ProMotion Drag-to-Reorder)
                includedIssuesSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)

            // Bottom Floating Search Drawer
            searchBottomDrawer
        }
    }

    // MARK: - Component 1: Volume Type Switcher

    private var volumeTypeSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Volume Strategy", selection: $volumeType) {
                ForEach(VolumeType.allCases) { type in
                    Label(type.tabTitle, systemImage: type.icon)
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)

            Text(volumeType.shortDescription)
                .font(.system(.caption2, design: .rounded))
                .foregroundColor(.inkTextSecondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Component 2: Pattern Suggestion Banner

    private var patternSuggestionBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundColor(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recurring Pattern Detected")
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundColor(.inkTextPrimary)

                Text("Volumes in \(seriesContextTitle) contain \(patternSuggestedIssues.count) issues each. Auto-fill Volume \(patternSuggestedVolumeNumber)?")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.inkTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                applyPatternSuggestion()
            } label: {
                Text("Auto-Fill")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.inkBlue, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation {
                    dismissedPatternSuggestion = true
                    showPatternBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundColor(.inkTextTertiary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous)
                .fill(Color.inkSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Component 3: Volume Configuration Section

    private var volumeConfigurationSection: some View {
        Section {
            // Volume Name Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Volume Name")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundColor(.inkTextSecondary)

                TextField("e.g. \(seriesContextTitle) Volume 1", text: $volumeName)
                    .font(.system(.body, design: .rounded))
                    .padding(10)
                    .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.inkBorderSubtle, lineWidth: 1)
                    )
            }
            .padding(.vertical, 4)

            // Mode-Specific Controls
            if volumeType == .assign {
                // Auto-Detect from Filenames button
                Button {
                    autoDetectVolumesFromFilenames()
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(.inkBlue)
                        Text("Auto-Detect Volume from Filenames")
                            .font(.system(.subheadline, design: .rounded).bold())
                            .foregroundColor(.inkTextPrimary)
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundColor(.inkTextSecondary)
                    }
                    .padding(.vertical, 4)
                }

                if !volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(role: .destructive) {
                        volumeName = ""
                        saveVolumeAssignment(volumeName: "")
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Clear Volume Tag from Issues")
                        }
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.red)
                        .padding(.vertical, 4)
                    }
                }
            } else {
                // Tag Issues in Series
                Toggle(isOn: $tagIssuesWithVolumeName) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tag issues with Volume in Series")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.inkTextPrimary)
                        Text("Writes volume number to issue metadata so they organize into collapsible shelves in the series view.")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundColor(.inkTextSecondary)
                    }
                }
                .padding(.vertical, 2)

                if volumeType == .virtual {
                    // Remote Sync URL
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remote Sync URL (ComicRack CBL / CSV)")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundColor(.inkTextSecondary)

                        TextField("https://example.com/readinglist.cbl", text: $remoteSyncURL)
                            .font(.system(.footnote, design: .rounded))
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.inkBorderSubtle, lineWidth: 1)
                            )

                        Text("Automatically syncs issue reading order from hosted reading lists.")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundColor(.inkTextSecondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    // Standalone Archive Options
                    Picker("Output Format", selection: $standaloneOutputFormat) {
                        ForEach(OutputFormat.allCases) { format in
                            Label(format.rawValue, systemImage: format.icon).tag(format)
                        }
                    }
                    .font(.system(.subheadline, design: .rounded))

                    Toggle("Manga Mode (Right-to-Left)", isOn: $mangaMode)
                        .font(.system(.subheadline, design: .rounded))

                    Toggle("Delete source files after merge", isOn: $deleteSourceFilesAfterMerge)
                        .font(.system(.subheadline, design: .rounded))

                    Picker("Compression Quality", selection: $settingsManager.conversionSettings.compressionQuality) {
                        ForEach(CompressionPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .font(.system(.subheadline, design: .rounded))

                    // Chapter Table of Contents (TOC) Options
                    if standaloneOutputFormat == .epub {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Generate Chapter Table of Contents (TOC)", isOn: $includeTOC)
                                .font(.system(.subheadline, design: .rounded).bold())

                            if includeTOC {
                                Picker("TOC Title Style", selection: $tocTitlePreset) {
                                    ForEach(ChapterTitleSanitizer.TitleFormatPreset.allCases) { preset in
                                        Text(preset.rawValue).tag(preset)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.top, 2)

                                Text("Kindle & in-app reader will display each chapter's first page as a selectable entry.")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(.inkTextSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } header: {
            Text("Volume Properties")
        }
        .listRowBackground(Color.inkSurfaceRaised)
    }

    // MARK: - Component 4: Smart Tools Section

    private var smartToolsSection: some View {
        Section {
            // Next-Issue Auto-Suggestion Chip
            if let nextIssue = nextSuggestedIssue {
                HStack(spacing: 10) {
                    Image(systemName: "plus.forwardslash.minus")
                        .foregroundColor(.inkGreen)
                        .font(.caption)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next Suggestion: \(nextIssue.name)")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundColor(.inkTextPrimary)
                            .lineLimit(1)
                        if let issueStr = nextIssue.metadata.issueNumber {
                            Text("Issue #\(issueStr)")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.inkTextSecondary)
                        }
                    }

                    Spacer()

                    Button {
                        HapticEngine.light()
                        withAnimation {
                            appendIssue(nextIssue)
                        }
                    } label: {
                        Text("Add")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.inkGreen, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            // Range Selector Tool
            HStack(spacing: 8) {
                Image(systemName: "number.square")
                    .foregroundColor(.inkBlue)
                    .font(.caption)

                Text("Select Range:")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundColor(.inkTextSecondary)

                TextField("From (e.g. 1)", text: $rangeStart)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 70)
                    .font(.system(.caption, design: .rounded))

                Text("to")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.inkTextSecondary)

                TextField("To (e.g. 6)", text: $rangeEnd)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 70)
                    .font(.system(.caption, design: .rounded))

                Spacer()

                Button("Add Range") {
                    applyRangeSelection()
                }
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(.inkBlue)
                .buttonStyle(.plain)
                .disabled(rangeStart.trimmingCharacters(in: .whitespaces).isEmpty || rangeEnd.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Smart Sequence Tools")
        }
        .listRowBackground(Color.inkSurfaceRaised)
    }

    // MARK: - Component 5: Smart Suggestions Section

    private var smartSuggestionsSection: some View {
        Section {
            ForEach(smartSuggestions) { pdf in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pdf.name)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.inkTextPrimary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let issue = pdf.metadata.issueNumber {
                                Text("Issue #\(issue)")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(.inkBlue)
                            }
                            Text(pdf.formattedSize)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.inkTextSecondary)
                        }
                    }

                    Spacer()

                    Button {
                        HapticEngine.light()
                        withAnimation {
                            appendIssue(pdf)
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.inkGreen)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Matching Suggestions")
                Spacer()
                Button("Add All") {
                    HapticEngine.medium()
                    withAnimation {
                        for pdf in smartSuggestions {
                            appendIssue(pdf)
                        }
                        smartSuggestions.removeAll()
                    }
                }
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(.inkBlue)
            }
        }
        .listRowBackground(Color.inkSurfaceRaised)
    }

    // MARK: - Component 6: Included Issues List

    private var includedIssuesSection: some View {
        Section {
            if selectedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 32))
                        .foregroundColor(.inkTextTertiary)
                    Text("No issues added yet")
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundColor(.inkTextSecondary)
                    Text("Use the range tool above or search below to assemble your volume.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.inkTextTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(selectedFiles.enumerated()), id: \.element.id) { index, pdf in
                    HStack(spacing: 12) {
                        // Drag Handle Icon
                        Image(systemName: "line.3.horizontal")
                            .font(.caption)
                            .foregroundColor(.inkTextTertiary)

                        // Issue Index Counter
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundColor(.inkTextSecondary)
                            .frame(width: 20, alignment: .center)

                        // File Info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pdf.name)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.inkTextPrimary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                if let issue = pdf.metadata.issueNumber {
                                    Text("Issue #\(issue)")
                                        .font(.system(.caption2, design: .rounded).bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.inkBlue.opacity(0.15), in: Capsule())
                                        .foregroundColor(.inkBlue)
                                }

                                Text("\(pdf.pageCount) pages")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(.inkTextSecondary)

                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.inkTextTertiary)

                                Text(pdf.formattedSize)
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(.inkTextSecondary)
                            }

                            // Editable Chapter Title for Table of Contents (Kindle & In-App)
                            if volumeType == .physicalMerge && includeTOC {
                                HStack(spacing: 5) {
                                    Image(systemName: "list.bullet.rectangle")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.inkBlue)
                                    TextField(
                                        "TOC Title...",
                                        text: Binding(
                                            get: { customChapterTitles[pdf.id] ?? resolvedChapterTitle(for: pdf, index: index) },
                                            set: { customChapterTitles[pdf.id] = $0 }
                                        )
                                    )
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.inkBackground.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                                }
                                .padding(.top, 2)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
                .onMove { indices, newOffset in
                    HapticEngine.light()
                    selectedFiles.move(fromOffsets: indices, toOffset: newOffset)
                    fileIDs = selectedFiles.map(\.id)
                }
                .onDelete { indices in
                    HapticEngine.medium()
                    selectedFiles.remove(atOffsets: indices)
                    fileIDs = selectedFiles.map(\.id)
                    updateSmartSuggestions()
                }
            }
        } header: {
            HStack {
                Text("Included Issues (\(selectedFiles.count))")
                Spacer()
                if !selectedFiles.isEmpty {
                    Text("\(totalPages) pgs • \(totalSizeFormatted)")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(.inkTextSecondary)
                    
                    Button("Clear All") {
                        HapticEngine.selection()
                        withAnimation {
                            selectedFiles.removeAll()
                            updateSmartSuggestions()
                        }
                    }
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundColor(.inkRed)
                    .padding(.leading, 6)
                }
            }
        } footer: {
            if !selectedFiles.isEmpty {
                Text("Drag handles on the right to reorder reading sequence. Swipe left to remove an issue.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.inkTextTertiary)
            }
        }
        .listRowBackground(Color.inkSurfaceRaised)
    }

    // MARK: - Component 7: Search Drawer

    private var searchBottomDrawer: some View {
        VStack(spacing: 8) {
            // Search Bar Input
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.inkTextSecondary)

                TextField("Search library to add issues...", text: $searchQuery)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.inkTextPrimary)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.inkTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous)
                    .strokeBorder(Color.inkBorderSubtle, lineWidth: 1)
            )
            .padding(.horizontal)

            // Expanded Search Results Dropdown
            if !searchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(searchResults) { pdf in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pdf.name)
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundColor(.inkTextPrimary)
                                        .lineLimit(1)
                                    Text(pdf.metadata.series ?? "Single Issue")
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundColor(.inkTextSecondary)
                                }

                                Spacer()

                                Button {
                                    HapticEngine.light()
                                    withAnimation {
                                        appendIssue(pdf)
                                        searchQuery = ""
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.inkBlue)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.inkSurfaceRaised)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .cornerRadius(InkRadius.thumbnail)
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .background(Color.inkBackground)
    }

    // MARK: - Actions & Persistence Engine

    private func appendIssue(_ pdf: ConvertedPDF) {
        guard !fileIDs.contains(pdf.id) else { return }
        fileIDs.append(pdf.id)
        selectedFiles.append(pdf)
        if existingOmnibus == nil {
            selectedFiles.sort(by: ConvertedPDF.naturalIssueSort)
            fileIDs = selectedFiles.map(\.id)
        }
        if !mangaMode && pdf.isMangaBook {
            mangaMode = true
        }
        updateSmartSuggestions()
    }

    private func reloadInitialFiles() {
        let all = conversionManager.visiblePDFs
        var loaded = fileIDs.compactMap { id in all.first(where: { $0.id == id }) }
        if existingOmnibus == nil {
            loaded.sort(by: ConvertedPDF.naturalIssueSort)
            fileIDs = loaded.map(\.id)
        }
        selectedFiles = loaded
        if volumeName.isEmpty, let first = selectedFiles.first {
            if let series = first.metadata.series, !series.isEmpty {
                volumeName = "\(series) Volume 1"
            } else {
                volumeName = "Volume 1"
            }
        }
        if !mangaMode {
            let hasManga = selectedFiles.contains(where: { $0.isMangaBook })
            if hasManga {
                mangaMode = true
            }
        }
    }

    private func handlePrimaryAction() {
        HapticEngine.medium()
        let trimmedName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedFiles.isEmpty else { return }

        switch volumeType {
        case .virtual:
            guard !trimmedName.isEmpty else { return }
            saveVirtualVolume(name: trimmedName)
        case .assign:
            saveVolumeAssignment(volumeName: trimmedName)
        case .physicalMerge:
            guard !trimmedName.isEmpty else { return }
            executePhysicalMerge(name: trimmedName)
        }
    }

    private func saveVolumeAssignment(volumeName: String) {
        let trimmed = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag: String? = trimmed.isEmpty ? nil : parseVolumeTag(from: trimmed)
        
        let currentSelectedIDs = Set(selectedFiles.map(\.id))
        
        // 1. If any issues were removed from this volume while editing in Volume Studio, clear their volume tag
        for id in fileIDs where !currentSelectedIDs.contains(id) {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == id }) {
                conversionManager.convertedPDFs[idx].metadata.volume = nil
            }
        }
        
        // 2. Set volume tag on currently selected files
        for file in selectedFiles {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == file.id }) {
                conversionManager.convertedPDFs[idx].metadata.volume = tag
            }
        }
        conversionManager.saveLibrary()
        NotificationCenter.default.post(name: .libraryUpdated, object: nil)
        HapticEngine.success()
        dismiss()
    }

    private func autoDetectVolumesFromFilenames() {
        HapticEngine.medium()
        let updatedCount = conversionManager.autoDetectVolumesFromFilenames(for: selectedFiles)
        if updatedCount > 0 {
            HapticEngine.success()
            dismiss()
        }
    }

    private func saveVirtualVolume(name: String) {
        let activeId = existingOmnibus?.id ?? UUID()
        let cleanSyncURL = remoteSyncURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = VirtualOmnibus(
            id: activeId,
            name: name,
            fileIDs: selectedFiles.map(\.id),
            coverFileID: existingOmnibus?.coverFileID ?? selectedFiles.first?.id,
            lastReadPageIndex: existingOmnibus?.lastReadPageIndex ?? 0,
            lastReadFileID: existingOmnibus?.lastReadFileID ?? selectedFiles.first?.id,
            addedAt: existingOmnibus?.addedAt ?? Date(),
            modifiedAt: Date(),
            remoteSyncURL: cleanSyncURL.isEmpty ? nil : cleanSyncURL,
            lastSyncedAt: existingOmnibus?.lastSyncedAt,
            parentSeriesID: parentSeriesID
        )

        var list = LibraryService.shared.virtualOmnibuses
        if let idx = list.firstIndex(where: { $0.id == activeId }) {
            list[idx] = record
        } else {
            list.append(record)
        }
        LibraryService.shared.virtualOmnibuses = list
        LibraryService.shared.saveVirtualOmnibuses()

        // Optionally tag individual issues with the volume identifier
        if tagIssuesWithVolumeName {
            applyVolumeMetadataToIssues(volumeName: name)
        }

        // Post reactive notifications for immediate live UI propagation
        NotificationCenter.default.post(name: .virtualOmnibusesDidChange, object: record)
        NotificationCenter.default.post(name: .libraryUpdated, object: nil)

        // Remote reading list background sync if applicable
        if let url = record.remoteSyncURL, !url.isEmpty, url != existingOmnibus?.remoteSyncURL {
            Task {
                await LibraryService.shared.syncRemoteVirtualOmnibus(record)
            }
        }

        HapticEngine.success()
        dismiss()
    }

    private func resolvedChapterTitle(for pdf: ConvertedPDF, index: Int) -> String {
        if let custom = customChapterTitles[pdf.id], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ChapterTitleSanitizer.sanitize(
            filename: pdf.name,
            fallbackIndex: index,
            seriesName: parentSeriesID ?? pdf.metadata.series,
            preset: tocTitlePreset
        )
    }

    private func executePhysicalMerge(name: String) {
        isProcessingMerge = true
        let files = selectedFiles
        let isManga = mangaMode
        let seriesTag = parentSeriesID ?? files.first?.metadata.series
        let orderedChapterTitles: [String]? = (includeTOC && standaloneOutputFormat == .epub)
            ? files.enumerated().map { idx, pdf in resolvedChapterTitle(for: pdf, index: idx) }
            : nil

        Task {
            let mergedBooks = await conversionManager.convertAndMerge(
                sourceFiles: files,
                outputName: name,
                mangaMode: isManga,
                overrideSeries: seriesTag,
                customChapterTitles: orderedChapterTitles
            )

            await MainActor.run {
                if let newBook = mergedBooks.first {
                    // Tag new volume if enabled
                    if tagIssuesWithVolumeName {
                        let volTag = parseVolumeTag(from: name)
                        if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == newBook.id }) {
                            conversionManager.convertedPDFs[idx].metadata.volume = volTag
                            conversionManager.saveLibrary()
                        }
                    }

                    if shouldDelete {
                        for file in files {
                            conversionManager.deletePDF(file)
                        }
                    }

                    NotificationCenter.default.post(name: .openMergedBook, object: newBook)
                    NotificationCenter.default.post(name: .libraryUpdated, object: nil)
                    NotificationCenter.default.post(name: .virtualOmnibusesDidChange, object: nil)
                }

                isProcessingMerge = false
                HapticEngine.success()
                dismiss()
            }
        }
    }

    private func applyVolumeMetadataToIssues(volumeName: String) {
        let tag = parseVolumeTag(from: volumeName)
        for file in selectedFiles {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == file.id }) {
                conversionManager.convertedPDFs[idx].metadata.volume = tag
            }
        }
        conversionManager.saveLibrary()
    }

    private func parseVolumeTag(from name: String) -> String {
        let pattern = #"(?i)v(?:ol(?:ume)?)?\.?\s*(\d+(?:\.\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = regex.firstMatch(in: name, options: [], range: range),
               let numRange = Range(match.range(at: 1), in: name) {
                return String(name[numRange])
            }
        }
        let parsed = DeterministicFilenameParser.parse(filename: name)
        if let v = parsed.volume, !v.isEmpty {
            return v
        }
        return name
    }

    // MARK: - Pattern Recognition Algorithms

    private func checkForVolumePatterns() {
        guard existingOmnibus == nil else { return }
        let pool = seriesPoolFiles
        guard pool.count >= 4 else { return }

        // Compile counts per volume
        var volumeCounts: [Int: Int] = [:]
        for file in pool {
            if let volStr = file.resolvedVolume, let volNum = Int(volStr) {
                volumeCounts[volNum, default: 0] += 1
            }
        }

        // Determine next volume number and pattern chunk size
        let patternSize: Int
        let nextVolume: Int
        
        if let count1 = volumeCounts[1], count1 > 0 {
            if let count2 = volumeCounts[2], count2 > 0 {
                let maxVolume = volumeCounts.keys.max() ?? 2
                nextVolume = maxVolume + 1
                patternSize = count2
            } else {
                nextVolume = 2
                patternSize = count1
            }
        } else if let maxVol = volumeCounts.keys.max(), let maxCount = volumeCounts[maxVol], maxCount > 0 {
            nextVolume = maxVol + 1
            patternSize = maxCount
        } else {
            nextVolume = 1
            patternSize = min(6, pool.count)
        }

        // If next volume is already populated, skip
        if let existingCount = volumeCounts[nextVolume], existingCount > 0 {
            return
        }

        // Find candidate issues for the next volume
        let unmergedIssues = pool.filter { file in
            if let volStr = file.resolvedVolume, let volNum = Int(volStr) {
                return volNum >= nextVolume || volNum == 0
            }
            return true
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        guard unmergedIssues.count >= patternSize else { return }

        self.patternSuggestedIssues = Array(unmergedIssues.prefix(patternSize))
        self.patternSuggestedVolumeNumber = nextVolume
        self.showPatternBanner = true
    }

    private func applyPatternSuggestion() {
        HapticEngine.medium()
        selectedFiles = patternSuggestedIssues
        fileIDs = patternSuggestedIssues.map(\.id)
        volumeName = "\(seriesContextTitle) Volume \(patternSuggestedVolumeNumber)"
        withAnimation {
            showPatternBanner = false
            dismissedPatternSuggestion = true
        }
    }

    private func applyRangeSelection() {
        HapticEngine.light()
        guard let start = Double(rangeStart.trimmingCharacters(in: .whitespaces)),
              let end = Double(rangeEnd.trimmingCharacters(in: .whitespaces)) else {
            return
        }

        let minNum = min(start, end)
        let maxNum = max(start, end)
        let selectedSet = Set(fileIDs)

        let matching = seriesPoolFiles.filter { pdf in
            guard !selectedSet.contains(pdf.id) else { return false }
            if let num = pdf.resolvedIssueNumber {
                return num >= minNum && num <= maxNum
            }
            return false
        }.sorted { ($0.resolvedIssueNumber ?? 0) < ($1.resolvedIssueNumber ?? 0) }

        withAnimation {
            for pdf in matching {
                appendIssue(pdf)
            }
            rangeStart = ""
            rangeEnd = ""
        }
    }

    private func updateSmartSuggestions() {
        guard !volumeName.isEmpty else {
            smartSuggestions = []
            return
        }
        let selectedSet = Set(fileIDs)
        let targetTitle = volumeName.lowercased()

        let matches = seriesPoolFiles.filter { pdf in
            guard !selectedSet.contains(pdf.id) else { return false }
            let candidateSeries = pdf.metadata.series ?? pdf.name
            let score = SeriesHeuristicsMatcher.shared.levenshteinSimilarity(between: candidateSeries.lowercased(), and: targetTitle)
            return score >= 0.70
        }
        smartSuggestions = Array(matches.prefix(5))
    }



    private func matchesSearchQuery(name: String, query: String) -> Bool {
        let cleanQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanQuery.isEmpty { return true }
        let lowerName = name.lowercased()

        if lowerName.contains(cleanQuery) { return true }

        let pattern = #"(ch|chapter|i|issue|vol|volume|v)\s*[-.]?\s*0*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(cleanQuery.startIndex..<cleanQuery.endIndex, in: cleanQuery)
            if let match = regex.firstMatch(in: cleanQuery, options: [], range: range) {
                if let numRange = Range(match.range(at: 2), in: cleanQuery) {
                    let numberString = String(cleanQuery[numRange])
                    let targetNumber = Int(numberString) ?? -1
                    if let fileNum = MetadataHeuristics.extractIssueNumber(from: name), Int(fileNum) == targetNumber {
                        return true
                    }
                }
            }
        }
        return false
    }
}
