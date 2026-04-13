import SwiftUI

struct SeriesDetailView: View {
    let series: SeriesGroup
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    var useNavigationStack: Bool
    @AppStorage("defaultSeriesSort") private var sortOption: SeriesSortOption = .issueNumber
    @AppStorage("fastBundleOmnibus") private var fastBundleOmnibus = false
    @AppStorage("manualOmnibusBuildsCount") private var manualOmnibusBuildsCount = 0
    
    @State private var headerCover: UIImage? = nil
    
    // Config Sheet & Prompt State
    @State private var showingOmnibusPrompt: Bool = false
    @State private var pendingConfigSelection: Set<UUID>? = nil
    @State private var mergeConfigSuggestedName: String? = nil
    
    // Batch Selection
    @State private var selection = Set<UUID>()
    @State private var isSelectionMode: Bool = false
    @State private var showingMergeConfig: Bool = false
    @State private var showBatchMetadataEditor: Bool = false
    
    // Context Menu State
    @State private var pdfToRename: ConvertedPDF?
    @State private var renameText = ""
    @State private var pdfToExport: ConvertedPDF?
    @State private var pdfToSearchMetadata: ConvertedPDF?
    @State private var pdfToAssignSeries: ConvertedPDF?
    @State private var assignSeriesText = ""
    @State private var pdfToRead: ConvertedPDF? // Added for Reader
    @State private var pdfToDelete: ConvertedPDF? // QoL: Delete confirmation gate

    enum SeriesSortOption: String, CaseIterable, Identifiable {
        case manual = "Custom Order"
        case issueNumber = "Issue Number"
        case titleAsc = "Title (A-Z)"
        case titleDesc = "Title (Z-A)"
        case dateNewest = "Date Added (Newest)"
        case dateOldest = "Date Added (Oldest)"
        case sizeLargest = "Size (Largest)"
        case sizeSmallest = "Size (Smallest)"
        var id: String { rawValue }
    }
    
    @State private var showBookmarksOnly = false // Added for filtering

    var sortedIssues: [ConvertedPDF] {
        var sorted = series.issues
        
        switch sortOption {
        case .manual:
            break // Retain the natively generated sequence passed from LibraryViewModel
        case .issueNumber:
            sorted.sort {
                let n1 = Double($0.metadata.issueNumber ?? "")
                let n2 = Double($1.metadata.issueNumber ?? "")
                if let v1 = n1, let v2 = n2 { return v1 < v2 }
                if n1 != nil && n2 == nil { return true }
                if n1 == nil && n2 != nil { return false }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .titleAsc:
            sorted.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .titleDesc:
            sorted.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateNewest:
            sorted.removeAll() // We can't trust original appending sequence chronologically due to bulk processing imports
            sorted = series.issues.reversed() // Fallback to inverted addition (approximating dateNewest for legacy items)
        case .dateOldest:
            break // Native loop append order is Date Added
        case .sizeLargest:
            sorted.sort { $0.fileSize > $1.fileSize }
        case .sizeSmallest:
            sorted.sort { $0.fileSize < $1.fileSize }
        }
        
        if showBookmarksOnly {
            return sorted.filter { !$0.metadata.bookmarkedPages.isEmpty }
        }
        return sorted
    }
    
    @State private var localIssues: [ConvertedPDF] = []
    
    // Volume Grouping State
    @State private var showVolumeGrouping: Bool = true
    @State private var collapsedVolumes: Set<String> = []
    @State private var showBatchVolumeAssignment = false
    @State private var jumpToVolume: String? = nil
    
    var isCollection: Bool {
        guard let id = UUID(uuidString: series.id) else { return false }
        return conversionManager.collections.contains(where: { $0.id == id })
    }
    
    /// Groups issues by their volume metadata for collapsible rendering
    var volumeGroups: [(key: String, issues: [ConvertedPDF])] {
        var groups: [String: [ConvertedPDF]] = [:]
        var ungrouped: [ConvertedPDF] = []
        
        for pdf in localIssues {
            if let vol = pdf.metadata.volume, !vol.isEmpty {
                groups[vol, default: []].append(pdf)
            } else {
                ungrouped.append(pdf)
            }
        }
        
        // Sort volume keys numerically
        var result = groups.map { (key: $0.key, issues: $0.value) }
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
        
        if !ungrouped.isEmpty {
            result.append((key: "Ungrouped", issues: ungrouped))
        }
        return result
    }
    
    /// True if any issues have volume metadata worth grouping by
    var hasVolumeData: Bool {
        localIssues.contains { $0.metadata.volume != nil && !($0.metadata.volume!.isEmpty) }
    }
    
    /// Detected missing issues in the series
    var missingIssues: [String] {
        MissingIssueDetector.detectGaps(in: localIssues)
    }
    
    /// Finds the next unread issue in reading order
    var nextUnreadIssue: ConvertedPDF? {
        for pdf in localIssues {
            let lastRead = pdf.metadata.lastReadPage ?? 0
            if lastRead < pdf.pageCount {
                return pdf
            }
        }
        return nil
    }
    
    /// Calculates reading progress (0.0–1.0) for a set of issues
    private func readingProgress(for issues: [ConvertedPDF]) -> Double {
        let totalPages = issues.reduce(0) { $0 + max($1.pageCount, 1) }
        let readPages = issues.reduce(0) { $0 + ($1.metadata.lastReadPage ?? 0) }
        guard totalPages > 0 else { return 0 }
        return Double(readPages) / Double(totalPages)
    }
    
    /// Zero-pads a volume string (if it's an integer) to ensure correct lexicographical sorting (01 vs 10)
    private func formattedVolumeKey(_ key: String) -> String {
        if let val = Int(key) {
            return String(format: "%02d", val)
        }
        return key
    }
    
    /// Count of fully completed issues in a group
    private func completedCount(for issues: [ConvertedPDF]) -> Int {
        issues.filter { ($0.metadata.lastReadPage ?? 0) >= $0.pageCount && $0.pageCount > 0 }.count
    }

    private var contentList: some View {
        List {
            Section(header: headerView) {
                // ── Continue Reading Smart Button ────────────────────────
                if let nextIssue = nextUnreadIssue {
                    Button {
                        pdfToRead = nextIssue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(
                                    LinearGradient(colors: [Theme.orange, Theme.red],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Continue Reading")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.textSecondary)
                                    .tracking(0.8)
                                
                                Text(nextIssue.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                
                                if let vol = nextIssue.metadata.volume, !vol.isEmpty,
                                   let issue = nextIssue.metadata.issueNumber {
                                    Text("Vol. \(vol) • Ch. \(issue) • Page \((nextIssue.metadata.lastReadPage ?? 0) + 1)")
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(Theme.orange)
                                } else {
                                    Text("Page \((nextIssue.metadata.lastReadPage ?? 0) + 1) of \(nextIssue.pageCount)")
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundColor(Theme.orange)
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.orange.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Theme.orange.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                }
                
                // ── Missing Issue Banner ──────────────────────────────
                if !missingIssues.isEmpty {
                    MissingIssueBanner(gaps: missingIssues)
                }
                
                if showVolumeGrouping && hasVolumeData {
                    // ── Collapsible Volume Sections ──────────────────────────
                    ForEach(volumeGroups, id: \.key) { group in
                        let isCollapsed = collapsedVolumes.contains(group.key)
                        let progress = readingProgress(for: group.issues)
                        let completed = completedCount(for: group.issues)
                        
                        // Volume Header (tap to collapse/expand)
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if isCollapsed {
                                    collapsedVolumes.remove(group.key)
                                } else {
                                    collapsedVolumes.insert(group.key)
                                }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                HStack(spacing: 10) {
                                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Theme.orange)
                                        .frame(width: 16)
                                    
                                    Image(systemName: completed == group.issues.count ? "book.closed.fill" : "book.closed")
                                        .font(.system(size: 14))
                                        .foregroundColor(completed == group.issues.count ? .green : (group.key == "Ungrouped" ? Theme.textSecondary : Theme.blue))
                                    
                                    Text(group.key == "Ungrouped" ? "Ungrouped Issues" : "Volume \(group.key)")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Theme.text)
                                    
                                    Spacer()
                                    
                                    Text("\(completed)/\(group.issues.count)")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(completed == group.issues.count ? .green : Theme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.text.opacity(0.08))
                                        .clipShape(Capsule())
                                }
                                
                                // Reading Progress Bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Theme.text.opacity(0.08))
                                            .frame(height: 3)
                                        
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(
                                                progress >= 1.0
                                                    ? AnyShapeStyle(Color.green)
                                                    : AnyShapeStyle(LinearGradient(colors: [Theme.orange, Theme.red], startPoint: .leading, endPoint: .trailing))
                                            )
                                            .frame(width: geo.size.width * CGFloat(min(progress, 1.0)), height: 3)
                                    }
                                }
                                .frame(height: 3)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface.opacity(0.5))
                        // Feature 3: Volume Omnibus Quick-Build (long-press)
                        .contextMenu {
                            Button {
                                if fastBundleOmnibus {
                                    // User opted-in to the background autobuilder
                                    conversionManager.enqueueOmnibus(
                                        name: "\(series.title) Vol. \(formattedVolumeKey(group.key))",
                                        sourceFiles: group.issues
                                    )
                                } else {
                                    // User prefers the manual control sheet
                                    manualOmnibusBuildsCount += 1
                                    let selectedIDs = Set(group.issues.map { $0.id })
                                    
                                    // Trigger the prompt instead of instantly showing if they hit the 3-build threshold
                                    if manualOmnibusBuildsCount == 3 {
                                        pendingConfigSelection = selectedIDs
                                        mergeConfigSuggestedName = "\(series.title) Vol. \(formattedVolumeKey(group.key))"
                                        showingOmnibusPrompt = true
                                    } else {
                                        selection = selectedIDs
                                        mergeConfigSuggestedName = "\(series.title) Vol. \(formattedVolumeKey(group.key))"
                                        showingMergeConfig = true
                                    }
                                }
                            } label: {
                                Label("Build Kindle Omnibus for Vol. \(formattedVolumeKey(group.key))", systemImage: "books.vertical.fill")
                            }
                            
                            Button {
                                withAnimation {
                                    if isCollapsed {
                                        collapsedVolumes.remove(group.key)
                                    } else {
                                        collapsedVolumes.insert(group.key)
                                    }
                                }
                            } label: {
                                Label(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            }
                        }
                        
                        // Volume Contents (shown when expanded)
                        if !isCollapsed {
                            ForEach(group.issues) { pdf in
                                issueRow(pdf)
                            }
                        }
                    }
                } else {
                    // ── Flat List (original behavior) ────────────────────────
                    ForEach(localIssues) { pdf in
                        issueRow(pdf)
                    }
                    .onMove { source, destination in
                        if isCollection {
                            localIssues.move(fromOffsets: source, toOffset: destination)
                            if let colID = UUID(uuidString: series.id) {
                                conversionManager.updateCollectionOrder(collectionID: colID, newOrderIDs: localIssues.map { $0.id })
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            localIssues = sortedIssues
        }
        .onChange(of: sortOption) { localIssues = sortedIssues }
        .onChange(of: conversionManager.convertedPDFs.count) { localIssues = sortedIssues }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(series.title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if isSelectionMode {
                        Button(action: {
                            withAnimation {
                                if selection.count == localIssues.count {
                                    selection.removeAll()
                                } else {
                                    selection = Set(localIssues.map { $0.id })
                                }
                            }
                        }) {
                            Text(selection.count == localIssues.count ? "Deselect All" : "Select All")
                        }
                    }
                    
                    Button(action: {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        withAnimation {
                            isSelectionMode.toggle()
                            selection.removeAll()
                        }
                    }) {
                        Text(isSelectionMode ? "Cancel" : "Select")
                            .bold(isSelectionMode)
                    }
                    
                    if !isSelectionMode {
                        Button {
                            withAnimation { showBookmarksOnly.toggle() }
                        } label: {
                            Image(systemName: showBookmarksOnly ? "bookmark.fill" : "bookmark")
                                .foregroundColor(showBookmarksOnly ? Theme.orange : .blue)
                        }

                        // Volume Grouping Toggle (only visible when volume data exists)
                        if hasVolumeData {
                            Button {
                                withAnimation { showVolumeGrouping.toggle() }
                            } label: {
                                Image(systemName: showVolumeGrouping ? "rectangle.3.group.fill" : "rectangle.3.group")
                                    .foregroundColor(showVolumeGrouping ? Theme.orange : .blue)
                            }
                        }

                        Menu {
                            Picker("Sort By", selection: $sortOption) {
                                if isCollection {
                                    Text(SeriesSortOption.manual.rawValue).tag(SeriesSortOption.manual)
                                }
                                ForEach(SeriesSortOption.allCases.filter { $0 != .manual }) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            
                            if showVolumeGrouping && hasVolumeData {
                                Divider()
                                
                                Button {
                                    withAnimation {
                                        collapsedVolumes = Set(volumeGroups.map { $0.key })
                                    }
                                } label: {
                                    Label("Collapse All Volumes", systemImage: "rectangle.compress.vertical")
                                }
                                
                                Button {
                                    withAnimation {
                                        collapsedVolumes.removeAll()
                                    }
                                } label: {
                                    Label("Expand All Volumes", systemImage: "rectangle.expand.vertical")
                                }
                            }
                            
                            Divider()
                            
                            // Feature 5: Smart List Template Export
                            Button {
                                exportSmartListTemplate()
                            } label: {
                                Label("Export as Smart List (.csv)", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        
                        if isCollection {
                            EditButton()
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        contentList
        .fullScreenCover(item: $pdfToRead) { pdf in
            if pdf.contentType == .book { SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) } else { ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf) }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                VStack(spacing: 0) {
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack(spacing: 16) {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            showBatchMetadataEditor = true
                        }) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Intelligent Metadata")
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(alignment: .center) {
                                if selection.isEmpty {
                                    Color.gray.opacity(0.3)
                                } else {
                                    LinearGradient(colors: [Theme.blue, Theme.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            .clipShape(Capsule())
                            .shadow(color: selection.isEmpty ? .clear : Theme.blue.opacity(0.3), radius: 5, y: 3)
                        }
                        .disabled(selection.isEmpty)
                        
                        Spacer()
                        
                        VStack(spacing: 2) {
                            Text("\(selection.count) Selected")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            Button {
                                showBatchVolumeAssignment = true
                            } label: {
                                Text("Assign Volume")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(selection.isEmpty ? .gray : Theme.orange)
                            }
                            .disabled(selection.isEmpty)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            mergeConfigSuggestedName = "\(series.title) Omnibus"
                            showingMergeConfig = true
                        }) {
                            HStack {
                                Text("Convert & Merge")
                                Image(systemName: "doc.on.doc.fill")
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(alignment: .center) {
                                if selection.count < 2 {
                                    Color.gray.opacity(0.3)
                                } else {
                                    LinearGradient(colors: [Color.purple, Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            .clipShape(Capsule())
                            .shadow(color: selection.count < 2 ? .clear : Color.purple.opacity(0.3), radius: 5, y: 3)
                        }
                        .disabled(selection.count < 2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea(edges: .bottom)
                            .shadow(color: .black.opacity(0.2), radius: 10, y: -5)
                    )
                }
                .transition(.move(edge: .bottom))
            }
        }
        .sheet(isPresented: $showingMergeConfig) {
            let filesToMerge = series.issues.filter { selection.contains($0.id) }
            SeriesMergeConfigurationView(sourceFiles: filesToMerge, suggestedName: mergeConfigSuggestedName)
        }
        .sheet(isPresented: $showBatchMetadataEditor) {
            let selectedFiles = series.issues.filter { selection.contains($0.id) }
            BatchMetadataEditorView(selectedPDFs: selectedFiles)
        }
        .sheet(item: $pdfToExport) { pdf in
            DualExportView(pdf: pdf)
        }
        .sheet(item: $pdfToSearchMetadata) { pdf in
            MetadataSearchSheet(pdf: pdf)
        }
        .sheet(isPresented: $showBatchVolumeAssignment) {
            BatchVolumeAssignmentSheet(selectedIDs: selection)
                .environmentObject(conversionManager)
        }
        .overlay {
            if showVolumeGrouping && hasVolumeData && volumeGroups.count > 4 {
                QuickVolumeJumpOverlay(volumeGroups: volumeGroups) { volKey in
                    jumpToVolume = volKey
                }
            }
        }
        .alert("Rename File", isPresented: Binding(
            get: { pdfToRename != nil },
            set: { if !$0 { pdfToRename = nil } }
        )) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let pdf = pdfToRename {
                    conversionManager.renamePDF(pdf, to: renameText)
                }
            }
        }
        .alert("Add to Series", isPresented: Binding(
            get: { pdfToAssignSeries != nil },
            set: { if !$0 { pdfToAssignSeries = nil } }
        )) {
            TextField("Series Name", text: $assignSeriesText)
            Button("Cancel", role: .cancel) { pdfToAssignSeries = nil }
            Button("Assign") {
                if let pdf = pdfToAssignSeries {
                    let name = assignSeriesText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        conversionManager.assignToSeries(pdf, seriesName: name)
                    }
                }
                pdfToAssignSeries = nil
            }
        } message: {
            Text("Enter the series name to group this file into a collection.")
        }
        .alert("Automate Omnibus Builds?", isPresented: $showingOmnibusPrompt) {
            Button("Enable Fast Bundle") {
                fastBundleOmnibus = true
                
                // Route them directly to background queue
                if let pending = pendingConfigSelection {
                    let files = series.issues.filter { pending.contains($0.id) }
                    conversionManager.enqueueOmnibus(name: "\(series.title) Omnibus", sourceFiles: files)
                }
                pendingConfigSelection = nil
            }
            Button("Keep Showing Control Sheet") {
                // If they deny, trigger the sheet
                if let pending = pendingConfigSelection {
                    selection = pending
                    showingMergeConfig = true
                }
                pendingConfigSelection = nil
            }
        } message: {
            Text("You've built 3 omnibuses manually. Would you like to enable 'Fast Bundle Mode' to automatically skip the configuration sheet and instantly queue omnibuses in the background using your saved settings?")
        }
        // QoL: Delete confirmation with Move to Trash option
        .alert("Delete File", isPresented: Binding(
            get: { pdfToDelete != nil },
            set: { if !$0 { pdfToDelete = nil } }
        )) {
            Button("Move to Trash", role: .destructive) {
                if let pdf = pdfToDelete {
                    // Move file to system trash instead of permanent delete
                    if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                        let fileURL = pdf.url
                        conversionManager.convertedPDFs.remove(at: idx)
                        conversionManager.saveLibrary()
                        Task.detached(priority: .background) {
                            try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                        }
                    }
                }
                pdfToDelete = nil
            }
            Button("Delete Permanently", role: .destructive) {
                if let pdf = pdfToDelete {
                    conversionManager.deletePDF(pdf)
                }
                pdfToDelete = nil
            }
            Button("Cancel", role: .cancel) { pdfToDelete = nil }
        } message: {
            Text("\"\(pdfToDelete?.name ?? "this file")\" will be removed. Move to Trash allows recovery via the Files app.")
        }
        .task(id: series.id) { await loadHeaderCover() }
    }
    
    // MARK: - Issue Row (Shared by flat + volume grouped views)
    
    @ViewBuilder
    private func issueRow(_ pdf: ConvertedPDF) -> some View {
        if isSelectionMode {
            Button {
                if selection.contains(pdf.id) {
                    selection.remove(pdf.id)
                } else {
                    selection.insert(pdf.id)
                }
            } label: {
                HStack {
                    LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                    Spacer()
                    Image(systemName: selection.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selection.contains(pdf.id) ? .blue : .gray)
                        .font(.title2)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(selection.contains(pdf.id) ? Color.blue.opacity(0.1) : Theme.bg)
            
        } else if useNavigationStack {
            NavigationLink(value: pdf) {
                LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
            }
            .swipeActions(edge: .leading) { swipeActionsLeading(pdf) }
            .swipeActions(edge: .trailing) { swipeActionsTrailing(pdf) }
            .contextMenu { contextMenuContent(pdf) }
        } else {
            Button {
                selectedPDF = pdf
            } label: {
                LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDF?.id == pdf.id)
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(selectedPDF?.id == pdf.id ? Theme.surfaceElevated : Theme.bg)
            .swipeActions(edge: .leading) { swipeActionsLeading(pdf) }
            .swipeActions(edge: .trailing) { swipeActionsTrailing(pdf) }
            .contextMenu { contextMenuContent(pdf) }
        }
    }

    var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                if let img = headerCover {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 120)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(width: 80, height: 120)
                        .overlay(Image(systemName: "books.vertical").foregroundColor(.gray))
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(series.title)
                        .font(.title2).bold()
                        .foregroundColor(.primary)
                    Text("\(series.count) Issues")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let publisher = series.issues.first?.metadata.publisher {
                        Text(publisher)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.top, 4)
                    }
                    
                    // Series-wide reading progress
                    let seriesProgress = readingProgress(for: localIssues)
                    let seriesCompleted = completedCount(for: localIssues)
                    
                    HStack(spacing: 6) {
                        Text("\(Int(seriesProgress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(seriesProgress >= 1.0 ? .green : Theme.orange)
                        
                        Text("\(seriesCompleted)/\(localIssues.count) read")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.top, 2)
                    
                    // QoL: Missing issue awareness
                    if !missingIssues.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("\(missingIssues.count) missing issue\(missingIssues.count == 1 ? "" : "s") detected")
                                .font(.system(size: 11, design: .rounded))
                        }
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                    }
                }
                .padding(.leading)
                Spacer()
            }
            
            // Series-wide progress bar
            let progress = readingProgress(for: localIssues)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.text.opacity(0.1))
                        .frame(height: 4)
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            progress >= 1.0
                                ? AnyShapeStyle(Color.green)
                                : AnyShapeStyle(LinearGradient(colors: [Theme.blue, Theme.orange], startPoint: .leading, endPoint: .trailing))
                        )
                        .frame(width: geo.size.width * CGFloat(min(progress, 1.0)), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical)
    }
    
    // MARK: - Feature 5: Smart List Template Export
    
    private func exportSmartListTemplate() {
        var csv = "volume,start_chapter,end_chapter,series\n"
        
        if hasVolumeData {
            for group in volumeGroups {
                guard group.key != "Ungrouped" else { continue }
                let issueNumbers = group.issues.compactMap { $0.metadata.issueNumber }.compactMap { Int($0) }.sorted()
                if let first = issueNumbers.first, let last = issueNumbers.last {
                    csv += "\(group.key),\(first),\(last),\(series.title)\n"
                }
            }
        } else {
            for pdf in localIssues {
                let issue = pdf.metadata.issueNumber ?? ""
                let vol = pdf.metadata.volume ?? ""
                csv += "\(vol),\(issue),\(issue),\(series.title)\n"
            }
        }
        
        let filename = "\(series.title.replacingOccurrences(of: " ", with: "_"))_SmartList.csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        
        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            
            // iPad requires popover source
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topVC.present(activityVC, animated: true)
        }
    }

    @ViewBuilder
    private func swipeActionsLeading(_ pdf: ConvertedPDF) -> some View {
        Button {
            pdfToExport = pdf
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .tint(.green)
    
        Button {
            pdfToSearchMetadata = pdf
        } label: { Label("Metadata", systemImage: "info.circle") }
        .tint(.blue)
        
        Button {
            renameText = pdf.name
            pdfToRename = pdf
        } label: { Label("Rename", systemImage: "pencil") }
        .tint(.orange)
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed", systemImage: "flame") }
        .tint(.purple)
    }
    
    @ViewBuilder
    private func swipeActionsTrailing(_ pdf: ConvertedPDF) -> some View {
        Button(role: .destructive) { pdfToDelete = pdf } label: { Label("Delete", systemImage: "trash") }
    }
    
    @ViewBuilder
    private func contextMenuContent(_ pdf: ConvertedPDF) -> some View {
        Button {
            pdfToRead = pdf
        } label: { Label("Read / Preview", systemImage: "book.pages") }
        
        Button {
            pdfToExport = pdf
        } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        
        Button {
            renameText = pdf.name
            pdfToRename = pdf
        } label: { Label("Rename", systemImage: "pencil") }
        
        Button {
            assignSeriesText = pdf.metadata.series ?? ""
            pdfToAssignSeries = pdf
        } label: { Label("Add to Series...", systemImage: "books.vertical") }
        
        if (pdf.metadata.series != nil && !pdf.metadata.series!.isEmpty) || pdf.collectionId != nil {
            Button {
                conversionManager.setExplicitSeriesCover(for: pdf)
            } label: { Label("Set as Series Cover", systemImage: "photo.on.rectangle") }
        }
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed Panels", systemImage: "flame") }
        
        Button(role: .destructive) { pdfToDelete = pdf } label: { Label("Delete", systemImage: "trash") }
        
        Divider()
        
        Button {
            withAnimation {
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].isPrivate.toggle()
                    conversionManager.saveLibrary()
                }
            }
        } label: { Label(pdf.isPrivate ? "Remove from Vault" : "Move to Vault", systemImage: pdf.isPrivate ? "lock.open" : "lock.fill") }
        Button {
            pdfToSearchMetadata = pdf
        } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
    }

    private func loadHeaderCover() async {
        guard let url = series.coverURL else { return }
        let img = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return UIImage?.none }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 160, height: 240))
        }.value
        await MainActor.run { headerCover = img }
    }
}


