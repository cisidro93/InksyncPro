import SwiftUI

// ============================================================================
// SmartCollectionDetailView
// ============================================================================
// Renders a filtered view of the library with:
// 1. Series grouping — cloud files grouped by metadata.series even before download
// 2. Inline download actions — single file or entire series batch
// 3. Storage-aware mode — series cards show "Browse / Download" without requiring
//    a full series download to form the group
// ============================================================================

struct SmartCollectionDetailView: View {
    let rule: SmartCollectionRule
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var viewStyle: ModernLibraryView.LibraryViewStyle = .grid
    @State private var filteredItems: [LibraryListItem] = []
    @State private var isTruncated = false
    @State private var selectedPDF: ConvertedPDF? = nil

    // Download progress observation
    @ObservedObject private var downloader = CloudDownloadManager.shared
    @ObservedObject private var tracker = ReaderProgressTracker.shared

    // Batch download state
    @State private var downloadingSeriesID: String? = nil
    @State private var downloadSeriesProgress: Double = 0

    // MARK: - Filter + Group

    private func recomputeFilter() {
        let allPDFs = conversionManager.convertedPDFs
        let rule = self.rule

        Task.detached(priority: .userInitiated) {
            let cap = 200
            var results: [ConvertedPDF]
            var truncated = false

            let progressSnapshot: [UUID: ReadingProgress] = await MainActor.run {
                Dictionary(uniqueKeysWithValues: allPDFs.compactMap { pdf in
                    ReaderProgressTracker.shared.progress(for: pdf.id).map { (pdf.id, $0) }
                })
            }

            switch rule {
            case .recentlyAdded:
                results = Array(allPDFs.sorted { $0.lastModified > $1.lastModified }.prefix(50))

            case .readingNow:
                results = allPDFs.filter {
                    let f = progressSnapshot[$0.id]?.completionFraction ?? 0
                    return f > 0 && f < 1
                }.sorted {
                    (progressSnapshot[$0.id]?.lastOpenedAt ?? .distantPast) >
                    (progressSnapshot[$1.id]?.lastOpenedAt ?? .distantPast)
                }

            case .allUnread:
                results = allPDFs.filter { (progressSnapshot[$0.id]?.completionFraction ?? 0) == 0 }
                    .sorted { $0.lastModified > $1.lastModified }
                if results.count > cap { results = Array(results.prefix(cap)); truncated = true }

            case .completed:
                results = allPDFs.filter { (progressSnapshot[$0.id]?.completionFraction ?? 0) >= 1 }
                    .sorted {
                        (progressSnapshot[$0.id]?.lastOpenedAt ?? .distantPast) >
                        (progressSnapshot[$1.id]?.lastOpenedAt ?? .distantPast)
                    }

            case .onDrive:
                results = allPDFs.filter { if case .linked = $0.sourceMode { return true }; return false }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if results.count > cap { results = Array(results.prefix(cap)); truncated = true }

            case .cloudLibrary:
                results = allPDFs.filter { if case .cloud = $0.sourceMode { return true }; return false }
                    .sorted { $0.lastModified > $1.lastModified }
                if results.count > cap { results = Array(results.prefix(cap)); truncated = true }
            }

            // Group into series — works even for cloud files not yet downloaded
            let items = groupIntoItems(results)

            await MainActor.run {
                filteredItems = items
                isTruncated = truncated
            }
        }
    }

    /// Groups a flat PDF list into .series and .single LibraryListItems.
    /// Series membership is determined by metadata.series — no download required.
    private nonisolated func groupIntoItems(_ pdfs: [ConvertedPDF]) -> [LibraryListItem] {
        var groups: [String: SeriesGroup] = [:]
        var singles: [ConvertedPDF] = []
        var order: [String: Int] = [:]

        for (i, pdf) in pdfs.enumerated() {
            if let seriesName = pdf.metadata.series, !seriesName.isEmpty {
                let key = "series_\(seriesName)"
                if order[key] == nil { order[key] = i }
                if groups[key] == nil {
                    groups[key] = SeriesGroup(id: seriesName, title: seriesName, coverIssueID: pdf.id, count: 0, issues: [])
                }
                groups[key]!.issues.append(pdf)
                groups[key]!.count += 1
            } else {
                let key = "single_\(pdf.id)"
                if order[key] == nil { order[key] = i }
                singles.append(pdf)
            }
        }

        // Sort issues inside each series numerically
        for key in groups.keys {
            groups[key]!.issues.sort {
                let a = Double($0.metadata.issueNumber ?? "") ?? Double.infinity
                let b = Double($1.metadata.issueNumber ?? "") ?? Double.infinity
                if a != b { return a < b }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if let first = groups[key]!.issues.first { groups[key]!.coverIssueID = first.id }
        }

        var items: [(Int, LibraryListItem)] = []
        for (key, group) in groups { items.append((order[key] ?? 0, .series(group))) }
        for pdf in singles { items.append((order["single_\(pdf.id)"] ?? 0, .single(pdf))) }
        items.sort { $0.0 < $1.0 }
        return items.map { $0.1 }
    }

    // MARK: - Body

    var body: some View {
        // NavigationStack is required — the grid/list cells contain NavigationLinks
        // to SeriesDetailView. On iOS 16+ a NavigationLink without a NavigationStack
        // ancestor crashes immediately.
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    Divider().background(Theme.text.opacity(0.1))

                    if filteredItems.isEmpty {
                        emptyState
                    } else {
                        contentArea
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(item: $selectedPDF) { pdf in
            UnifiedReaderView(pdf: pdf)
                .environmentObject(conversionManager)
        }
        .task { recomputeFilter() }
        .onChange(of: conversionManager.convertedPDFs.count) { recomputeFilter() }
        .onReceive(tracker.objectWillChange) { recomputeFilter() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.iconName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(rule.tintColor.gradient)

            Text(rule.rawValue)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Theme.text)

            Spacer()

            let totalFiles = filteredItems.reduce(0) { sum, item in
                switch item {
                case .single: return sum + 1
                case .series(let g): return sum + g.count
                case .driveFolder: return sum
                }
            }

            Text("\(totalFiles) FILES")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
                .tracking(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surface)
                .clipShape(Capsule())

            Button { withAnimation { viewStyle = viewStyle == .grid ? .list : .grid } } label: {
                Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewStyle == .grid {
                    gridContent
                } else {
                    listContent
                }
                if isTruncated {
                    Text("Showing first 200 items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
    }

    // MARK: - Grid

    private var gridContent: some View {
        let hPad: CGFloat = hSizeClass == .regular ? 20 : 16
        let minW: CGFloat  = hSizeClass == .regular ? 180 : 100
        let maxW: CGFloat  = hSizeClass == .regular ? 320 : 280
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: minW, maximum: maxW), spacing: hSizeClass == .regular ? 20 : 16)], spacing: hSizeClass == .regular ? 24 : 20) {
            ForEach(filteredItems) { item in
                switch item {
                case .single(let pdf):
                    cloudAwareSingleCell(pdf: pdf)
                case .series(let group):
                    cloudAwareSeriesCell(group: group)
                case .driveFolder:
                    EmptyView()
                }
            }
        }
        .padding(hPad)
    }

    // MARK: - List

    private var listContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredItems) { item in
                switch item {
                case .single(let pdf):
                    cloudAwareListRow(pdf: pdf)
                    Divider().background(Theme.text.opacity(0.08)).padding(.leading, 56)
                case .series(let group):
                    cloudAwareSeriesListRow(group: group)
                    Divider().background(Theme.text.opacity(0.08)).padding(.leading, 56)
                case .driveFolder:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Grid Cells

        Button {
            handleSingleTap(pdf)
        } label: {
            ZStack(alignment: .bottom) {
                ModernGridFileCell(pdf: pdf, isSelected: false, isBatch: false)

                if isCloud {
                    if let p = progress {
                        // In-progress download bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5)).frame(height: 3)
                                Rectangle().fill(Theme.orange).frame(width: geo.size.width * p, height: 3)
                            }
                        }
                        .frame(height: 3)
                    } else {
                        // Download badge overlay
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Cloud")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                    }
                }
            }
        }
        .buttonStyle(CellButtonStyle())
        .contextMenu { singleContextMenu(pdf) }
    }

    @ViewBuilder
    private func cloudAwareSeriesCell(group: SeriesGroup) -> some View {
        let allCloud = group.issues.allSatisfy { if case .cloud = $0.sourceMode { return true }; return false }
        let anyCloud = group.issues.contains { if case .cloud = $0.sourceMode { return true }; return false }
        let isDownloadingThis = downloadingSeriesID == group.id

        ZStack(alignment: .topTrailing) {
            // Tap → navigate to series detail
            NavigationLink(destination:
                SeriesDetailView(series: group, selectedPDF: .constant(nil), useNavigationStack: false)
                    .environmentObject(conversionManager)
            ) {
                ModernGridSeriesCell(group: group, isSelected: false, isBatch: false)
            }
            .buttonStyle(PlainButtonStyle())

            if anyCloud {
                if isDownloadingThis {
                    ProgressView(value: downloadSeriesProgress)
                        .progressViewStyle(.circular)
                        .tint(Theme.orange)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                } else {
                    Button { downloadSeries(group) } label: {
                        Image(systemName: allCloud ? "icloud.and.arrow.down.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.orange)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(6)
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .contextMenu { seriesContextMenu(group) }
    }

    // MARK: - List Rows

    @ViewBuilder
    private func cloudAwareListRow(pdf: ConvertedPDF) -> some View {
        let isCloud = { if case .cloud = pdf.sourceMode { return true }; return false }()
        let remoteID = { if case .cloud(_, let id) = pdf.sourceMode { return id }; return "" }()
        let progress = downloader.streamProgress[remoteID] ?? downloader.activeDownloads[remoteID]

        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(width: 40, height: 56)
                if let img = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: isCloud ? "icloud.fill" : "doc.richtext")
                        .foregroundStyle(isCloud ? Theme.orange : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(pdf.name).font(.subheadline).foregroundStyle(Theme.text).lineLimit(2)
                if let series = pdf.metadata.series {
                    Text(series).font(.caption2).foregroundStyle(.secondary)
                }
                if isCloud {
                    if let p = progress {
                        ProgressView(value: p).tint(Theme.orange).frame(maxWidth: 120)
                    } else {
                        Text("In Cloud").font(.caption2).foregroundStyle(Theme.orange)
                    }
                }
            }

            Spacer()

            // Action button
            if isCloud {
                Menu {
                    Button { handleSingleTap(pdf) } label: { Label("Read Now", systemImage: "play.fill") }
                    Button { downloadFile(pdf, thenConvert: false) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    Button { downloadFile(pdf, thenConvert: true) } label: { Label("Download & Convert", systemImage: "arrow.down.circle.fill") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3).foregroundStyle(Theme.orange)
                }
            } else {
                Button { handleSingleTap(pdf) } label: {
                    Image(systemName: "play.fill").font(.system(size: 14))
                        .foregroundStyle(Theme.orange)
                        .frame(width: 36, height: 36)
                        .background(Theme.orange.opacity(0.12), in: Circle())
                }
            }
        }
        .padding(.horizontal, hSizeClass == .regular ? 20 : 16).padding(.vertical, 10)
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { handleSingleTap(pdf) }
    }

    @ViewBuilder
    private func cloudAwareSeriesListRow(group: SeriesGroup) -> some View {
        let anyCloud = group.issues.contains { if case .cloud = $0.sourceMode { return true }; return false }
        let allCloud = group.issues.allSatisfy { if case .cloud = $0.sourceMode { return true }; return false }
        let isDownloadingThis = downloadingSeriesID == group.id

        NavigationLink(destination:
            SeriesDetailView(series: group, selectedPDF: .constant(nil), useNavigationStack: false)
                .environmentObject(conversionManager)
        ) {
            HStack(spacing: 12) {
                // Cover stack
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(width: 40, height: 56)
                    if let coverID = group.coverIssueID,
                       let cover = group.issues.first(where: { $0.id == coverID }),
                       let img = conversionManager.getThumbnail(for: cover) {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: anyCloud ? "icloud.fill" : "books.vertical.fill")
                            .foregroundStyle(anyCloud ? Theme.orange : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.headline).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text("\(group.count) issue\(group.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        if allCloud {
                            Text("· All in Cloud").font(.caption).foregroundStyle(Theme.orange)
                        } else if anyCloud {
                            let cloudCount = group.issues.filter { if case .cloud = $0.sourceMode { return true }; return false }.count
                            Text("· \(cloudCount) in Cloud").font(.caption).foregroundStyle(Theme.orange)
                        }
                    }
                }

                Spacer()

                if anyCloud {
                    if isDownloadingThis {
                        ProgressView().controlSize(.small).tint(Theme.orange)
                    } else {
                        Button { downloadSeries(group) } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3).foregroundStyle(Theme.orange)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, hSizeClass == .regular ? 20 : 16).padding(.vertical, 10)
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu { seriesContextMenu(group) }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.fill").font(.system(size: 40)).foregroundStyle(Theme.text.opacity(0.2))
            Text("No items found.").foregroundStyle(Theme.textSecondary).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func singleContextMenu(_ pdf: ConvertedPDF) -> some View {
        let isCloud = { if case .cloud = pdf.sourceMode { return true }; return false }()
        Button { handleSingleTap(pdf) } label: { Label("Read Now", systemImage: "book.fill") }
        if isCloud {
            Divider()
            Button { downloadFile(pdf, thenConvert: false) } label: { Label("Download", systemImage: "arrow.down.circle") }
            Button { downloadFile(pdf, thenConvert: true) } label: { Label("Download & Convert", systemImage: "arrow.down.circle.fill") }
        }
    }

    @ViewBuilder
    private func seriesContextMenu(_ group: SeriesGroup) -> some View {
        let anyCloud = group.issues.contains { if case .cloud = $0.sourceMode { return true }; return false }
        if let next = nextUnread(in: group) {
            Button { handleSingleTap(next) } label: { Label("Read Next Issue", systemImage: "play.fill") }
        }
        if anyCloud {
            Divider()
            Button { downloadSeries(group) } label: { Label("Download Entire Series", systemImage: "arrow.down.circle.fill") }
            let settingsReady = AppSettingsManager.shared.conversionSettings.isConfigured
            if settingsReady {
                Button { downloadAndConvertSeries(group) } label: { Label("Download & Convert All", systemImage: "arrow.down.circle.fill") }
            }
        }
    }

    // MARK: - Actions

    private func handleSingleTap(_ pdf: ConvertedPDF) {
        // Cloud files: stream directly into reader (ReaderView handles this via CloudStreamCoordinator)
        // Local/linked files: open reader directly
        selectedPDF = pdf
    }

    private func downloadFile(_ pdf: ConvertedPDF, thenConvert: Bool) {
        let mgr = conversionManager
        Task {
            await CloudDownloadManager.shared.downloadAndStore(pdf: pdf, thenConvert: thenConvert, manager: mgr)
            recomputeFilter()
        }
    }

    private func downloadSeries(_ group: SeriesGroup) {
        let cloudIssues = group.issues.filter { if case .cloud = $0.sourceMode { return true }; return false }
        guard !cloudIssues.isEmpty else { return }
        downloadingSeriesID = group.id
        downloadSeriesProgress = 0
        let mgr = conversionManager
        Task {
            for (i, pdf) in cloudIssues.enumerated() {
                await CloudDownloadManager.shared.downloadAndStore(pdf: pdf, thenConvert: false, manager: mgr)
                await MainActor.run { downloadSeriesProgress = Double(i + 1) / Double(cloudIssues.count) }
            }
            await MainActor.run { downloadingSeriesID = nil; downloadSeriesProgress = 0 }
            recomputeFilter()
        }
    }

    private func downloadAndConvertSeries(_ group: SeriesGroup) {
        let cloudIssues = group.issues.filter { if case .cloud = $0.sourceMode { return true }; return false }
        guard !cloudIssues.isEmpty else { return }
        downloadingSeriesID = group.id
        downloadSeriesProgress = 0
        let mgr = conversionManager
        Task {
            for (i, pdf) in cloudIssues.enumerated() {
                await CloudDownloadManager.shared.downloadAndStore(pdf: pdf, thenConvert: true, manager: mgr)
                await MainActor.run { downloadSeriesProgress = Double(i + 1) / Double(cloudIssues.count) }
            }
            await MainActor.run { downloadingSeriesID = nil; downloadSeriesProgress = 0 }
            recomputeFilter()
        }
    }

    private func nextUnread(in group: SeriesGroup) -> ConvertedPDF? {
        group.issues
            .sorted {
                (Double($0.metadata.issueNumber ?? "") ?? .infinity) <
                (Double($1.metadata.issueNumber ?? "") ?? .infinity)
            }
            .first { (ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0) < 0.95 }
            ?? group.issues.first
    }
}
