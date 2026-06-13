import SwiftUI

// ============================================================================
// LinkedDriveBrowserView
// ============================================================================
// An on-demand folder-tree browser for a large linked external drive.
// Files are loaded lazily per-directory using the drive's persistent
// security-scoped bookmark — nothing is pre-loaded into convertedPDFs.
//
// Design: Infuse-style drill-down. Each directory level is its own NavigationLink.
// Files can be individually "Added to Library" (enters convertedPDFs) or read
// directly without library registration (ephemeral reader session).
// ============================================================================

struct LinkedDriveBrowserView: View {

    let driveEntry: AppSettingsManager.LinkedDriveEntry
    /// Current directory being browsed — nil means root of the drive.
    var directoryURL: URL? = nil

    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var driveMonitor = DriveMonitor.shared

    @State private var items: [BrowseItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var selectedPDF: ConvertedPDF? = nil

    private var isConnected: Bool { driveMonitor.isConnected(driveID: driveEntry.id) }

    // MARK: - Browse Item Model

    private struct BrowseItem: Identifiable {
        enum Kind { case folder(URL), file(URL) }
        let id: String
        let name: String
        let kind: Kind
        var fileSize: Int64 = 0

        var isFolder: Bool { if case .folder = kind { return true }; return false }
        var url: URL {
            switch kind {
            case .folder(let u): return u
            case .file(let u):   return u
            }
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else {
                contentList
            }
        }
        .navigationTitle(directoryURL?.lastPathComponent ?? driveEntry.displayName)
        .navigationBarTitleDisplayMode(.large)
        .task { await loadDirectory() }
        .fullScreenCover(item: $selectedPDF) { pdf in
            UnifiedReaderView(pdf: pdf)
        }
    }

    // MARK: - Content List

    private var contentList: some View {
        List {
            if items.isEmpty {
                Label("No supported files found in this folder.", systemImage: "doc.questionmark")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            // Folders first
            let folders = items.filter { $0.isFolder }
            let files   = items.filter { !$0.isFolder }

            if !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders) { item in
                        if case .folder(let url) = item.kind {
                            NavigationLink(destination:
                                LinkedDriveBrowserView(driveEntry: driveEntry, directoryURL: url)
                                    .environmentObject(conversionManager)
                            ) {
                                folderRow(item)
                            }
                        }
                    }
                }
            }

            if !files.isEmpty {
                Section("\(files.count) file\(files.count == 1 ? "" : "s")") {
                    ForEach(files) { item in
                        fileRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Row Views

    @ViewBuilder
    private func folderRow(_ item: BrowseItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color(hex: "#FFB340"))
                .frame(width: 32)
            Text(item.name)
                .font(.body)
                .foregroundStyle(Theme.text)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fileRow(_ item: BrowseItem) -> some View {
        HStack(spacing: 12) {
            // Format badge
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.orange.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text(item.url.pathExtension.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            // Quick-read button
            Button {
                openForReading(item)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.orange)
                    .frame(width: 32, height: 32)
                    .background(Theme.orange.opacity(0.12), in: Circle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button {
                addToLibrary(item)
            } label: {
                Label("Add to Library", systemImage: "plus.circle.fill")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button {
                openForReading(item)
            } label: {
                Label("Read", systemImage: "book.fill")
            }
            .tint(Theme.orange)
        }
    }

    // MARK: - Loading / Error Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.orange)
            Text("Browsing \(driveEntry.displayName)…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") { Task { await loadDirectory() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.orange)
        }
    }

    // MARK: - Directory Loading

    private func loadDirectory() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let rootURL = try BookmarkResolver.shared.resolve(driveEntry.volumeBookmarkData)
            let targetURL = directoryURL ?? rootURL
            let didAccess = targetURL.startAccessingSecurityScopedResource()
            defer { if didAccess { targetURL.stopAccessingSecurityScopedResource() } }

            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                await MainActor.run {
                    errorMessage = "Drive folder not accessible. Please reconnect the drive."
                    isLoading = false
                }
                return
            }

            let supportedExts = Set(["pdf", "epub", "cbz", "cbr", "cb7", "cbt", "zip"])
            let fm = FileManager.default
            let children = try fm.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )

            var discovered: [BrowseItem] = []
            for url in children {
                let res = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = res?.isDirectory ?? false
                let name = url.lastPathComponent
                if isDir {
                    discovered.append(BrowseItem(id: url.path, name: name, kind: .folder(url)))
                } else if supportedExts.contains(url.pathExtension.lowercased()) {
                    let size = Int64(res?.fileSize ?? 0)
                    discovered.append(BrowseItem(id: url.path, name: url.deletingPathExtension().lastPathComponent, kind: .file(url), fileSize: size))
                }
            }

            discovered.sort {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

            await MainActor.run {
                items = discovered
                isLoading = false
            }

        } catch {
            await MainActor.run {
                errorMessage = "Could not access drive: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    // MARK: - Actions

    private func openForReading(_ item: BrowseItem) {
        guard case .file(let url) = item.kind else { return }
        let ext = url.pathExtension.lowercased()
        let type: ContentType = (ext == "epub") ? .book : .comic
        var tempPDF = ConvertedPDF(
            name: item.name,
            url: url,
            pageCount: 0,
            fileSize: item.fileSize,
            metadata: PDFMetadata(title: item.name),
            contentType: type
        )
        // Encode a per-file bookmark so the reader can acquire security scope
        if let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            tempPDF.sourceMode = .linked(bookmarkData: bm)
        }
        selectedPDF = tempPDF
    }

    private func addToLibrary(_ item: BrowseItem) {
        guard case .file(let url) = item.kind else { return }
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }

        let stem = url.deletingPathExtension().lastPathComponent
        let fileSize = item.fileSize
        var metadata = PDFMetadata(title: stem)
        metadata.series = SeriesNameDetector.detect(from: url.lastPathComponent).seriesName

        var pdf = ConvertedPDF(
            name: stem,
            url: url,
            pageCount: 0,
            fileSize: fileSize,
            metadata: metadata
        )
        pdf.sourceMode = .linked(bookmarkData: bm)

        Task { @MainActor in
            guard !conversionManager.convertedPDFs.contains(where: {
                $0.url.lastPathComponent == url.lastPathComponent && $0.isLinked
            }) else { return }
            conversionManager.convertedPDFs.append(pdf)
            conversionManager.saveLibrary()
        }
    }
}
