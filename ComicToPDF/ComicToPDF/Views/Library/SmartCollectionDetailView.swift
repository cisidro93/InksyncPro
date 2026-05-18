import SwiftUI

struct SmartCollectionDetailView: View {
    let rule: SmartCollectionRule
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss

    // UI Layout state mapped from main library to ensure consistency
    @State private var viewStyle: ModernLibraryView.LibraryViewStyle = .grid
    @State private var sortOption: ModernLibraryView.SortOption = .dateAdded

    // Bindings required by shared grid/list components
    @State private var mockBatchMode = false
    @State private var mockMultiSelection: Set<UUID> = []
    @State private var selectedPDF: ConvertedPDF? = nil

    // Cached result — computed once and updated only when source data changes.
    @State private var filteredPDFs: [ConvertedPDF] = []
    @State private var isTruncated: Bool = false

    // Force view updates when tracker changes
    @ObservedObject private var tracker = ReaderProgressTracker.shared

    // MARK: - Async Filter

    /// Runs the filter on a background Task so it never blocks the main thread.
    /// Pre-snapshots the progress dictionary once to eliminate O(n log n) repeated lookups.
    private func recomputeFilter() {
        let allPDFs = conversionManager.convertedPDFs
        let rule = self.rule

        Task.detached(priority: .userInitiated) {
            // Snapshot the progress map once — avoids repeated main-actor hops inside the sort comparator.
            let progressSnapshot: [UUID: ReadingProgress] = await MainActor.run {
                var map: [UUID: ReadingProgress] = [:]
                for pdf in allPDFs {
                    if let prog = ReaderProgressTracker.shared.progress(for: pdf.id) {
                        map[pdf.id] = prog
                    }
                }
                return map
            }

            var results: [ConvertedPDF]
            var truncated = false
            let cap = 200   // Maximum items rendered in a single smart collection

            switch rule {
            case .recentlyAdded:
                results = allPDFs.sorted { $0.lastModified > $1.lastModified }
                if results.count > 50 { results = Array(results.prefix(50)) }

            case .readingNow:
                results = allPDFs.filter { pdf in
                    guard let p = progressSnapshot[pdf.id] else { return false }
                    return p.completionFraction > 0.0 && p.completionFraction < 1.0
                }
                results.sort { a, b in
                    let d1 = progressSnapshot[a.id]?.lastOpenedAt ?? .distantPast
                    let d2 = progressSnapshot[b.id]?.lastOpenedAt ?? .distantPast
                    return d1 > d2
                }

            case .allUnread:
                results = allPDFs.filter { pdf in
                    (progressSnapshot[pdf.id]?.completionFraction ?? 0.0) == 0.0
                }
                results.sort { $0.lastModified > $1.lastModified }
                if results.count > cap {
                    results = Array(results.prefix(cap))
                    truncated = true
                }

            case .completed:
                results = allPDFs.filter { pdf in
                    (progressSnapshot[pdf.id]?.completionFraction ?? 0.0) >= 1.0
                }
                results.sort { a, b in
                    let d1 = progressSnapshot[a.id]?.lastOpenedAt ?? .distantPast
                    let d2 = progressSnapshot[b.id]?.lastOpenedAt ?? .distantPast
                    return d1 > d2
                }

            case .manga:
                results = allPDFs.filter { progressSnapshot[$0.id]?.prefersMangaMode == true }
                results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            case .onDrive:
                // Files sourced from a linked external drive (USB, Dropbox folder, etc.)
                results = allPDFs.filter { pdf in
                    if case .linked = pdf.sourceMode { return true }
                    return false
                }
                results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if results.count > cap {
                    results = Array(results.prefix(cap))
                    truncated = true
                }

            case .cloudLibrary:
                // Files sourced from a cloud provider (Dropbox, Google Drive, iCloud)
                results = allPDFs.filter { pdf in
                    if case .cloud = pdf.sourceMode { return true }
                    return false
                }
                results.sort { $0.lastModified > $1.lastModified }
                if results.count > cap {
                    results = Array(results.prefix(cap))
                    truncated = true
                }
            }

            await MainActor.run {
                filteredPDFs = results
                isTruncated = truncated
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: rule.iconName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(rule.tintColor.gradient)

                    Text(rule.rawValue)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(Theme.text)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(filteredPDFs.count) ITEMS")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.textSecondary)
                            .tracking(1.0)
                        if isTruncated {
                            Text("Showing first 200")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(Theme.textSecondary.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surface)
                    .clipShape(Capsule())

                    Button {
                        withAnimation { viewStyle = viewStyle == .grid ? .list : .grid }
                    } label: {
                        Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider().background(Theme.text.opacity(0.1))

                if filteredPDFs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.text.opacity(0.2))
                        Text("No items found.")
                            .foregroundColor(Theme.textSecondary)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        if viewStyle == .grid {
                            LibraryGridView(
                                items: filteredPDFs.map { .single($0) },
                                isBatchMode: $mockBatchMode,
                                multiSelection: $mockMultiSelection,
                                useNavigationStack: false,
                                tapAction: .constant(.read),
                                selectedPDF: $selectedPDF,
                                onAction: { _, _ in },
                                onImport: {},
                                onFolderTap: { _ in },
                                onDropApplied: {}
                            )
                            .padding(.top, 16)
                        } else {
                            LibraryListView(
                                items: filteredPDFs.map { .single($0) },
                                isBatchMode: $mockBatchMode,
                                multiSelection: $mockMultiSelection,
                                useNavigationStack: false,
                                tapAction: .constant(.read),
                                selectedPDF: $selectedPDF,
                                onAction: { _, _ in },
                                onImport: {},
                                onFolderTap: { _ in }
                            )
                            .padding(.top, 16)
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        // Tap-to-read: opens correct reader for the selected PDF
        .fullScreenCover(item: $selectedPDF) { pdf in
            if pdf.contentType == .book {
                SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
            } else {
                ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
            }
        }
        // Compute once on appear
        .task { recomputeFilter() }
        // Recompute if the library changes (import, delete, rename)
        .onChange(of: conversionManager.convertedPDFs.count) { recomputeFilter() }
        // Recompute if any reading progress changes (page turn, markComplete)
        .onReceive(tracker.objectWillChange) { recomputeFilter() }
    }
}

