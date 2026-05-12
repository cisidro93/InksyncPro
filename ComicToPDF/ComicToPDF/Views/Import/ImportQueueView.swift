import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - Import Queue View

struct ImportQueueView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var queue = ImportQueueManager.shared
    @Environment(\.dismiss) private var dismiss

    // Duplicate handling
    @State private var pendingDuplicates: [URL] = []
    @State private var showDuplicateAlert = false

    // Series conflict handling
    @State private var showSeriesConflict = false
    @State private var pendingConflictGroups: [(seriesName: String, urls: [URL])] = []

    // Import summary
    @State private var importSummaries: [ImportSummary] = []
    @State private var showImportSummary = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                if queue.stagedURLs.isEmpty {
                    emptyStateView
                } else {
                    stagedListView
                }

                // Staging-in-progress overlay
                if queue.isStagingFiles {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.primary).scaleEffect(1.3)
                        if let progress = queue.stagingProgress {
                            Text("Staging \(progress.current) of \(progress.total) files…")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                        } else {
                            Text("Scanning folder…")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(28)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle("Import Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.blue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Import All") { importAll() }
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
                        .disabled(queue.stagedURLs.isEmpty)
                }
            }
            // Duplicate files alert
            .alert("Duplicates Detected", isPresented: $showDuplicateAlert) {
                Button("Skip Duplicates", role: .cancel) { pendingDuplicates = [] }
                Button("Import Anyway") {
                    queue.forceStage(pendingDuplicates)
                    pendingDuplicates = []
                }
            } message: {
                Text("\(pendingDuplicates.count) file(s) already exist in your queue. Import anyway?")
            }
            // Series name conflict sheet
            .sheet(isPresented: $showSeriesConflict) {
                SeriesConflictView(
                    conflictingGroups: pendingConflictGroups,
                    onAddToExisting: { group in
                        Task {
                            await conversionManager.importFilesAsSeries(
                                urls: group.urls,
                                seriesName: group.seriesName,
                                addToExisting: true
                            )
                        }
                    },
                    onCreateNew: { group in
                        Task {
                            await conversionManager.importFilesAsSeries(
                                urls: group.urls,
                                seriesName: "\(group.seriesName) (New)",
                                addToExisting: false
                            )
                        }
                    }
                )
            }
            .sheet(isPresented: $showImportSummary) {
                ImportSummaryView(summaries: importSummaries) { failedURLs in
                    // Retry: re-stage failed files
                    queue.forceStage(failedURLs)
                    showImportSummary = false
                }
            }
            .onChange(of: showSeriesConflict) { _, newValue in
                if newValue == false && queue.stagedURLs.isEmpty {
                    dismiss()
                }
            }
        }
    }

    // MARK: Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 68))
                .foregroundStyle(Color.orange.gradient)

            Text("Staging Queue Is Empty")
                .font(.title2.bold())
                .foregroundColor(.primary)

            Text("Add comics from different folders into this queue. Once you've selected everything, tap 'Import All' to process them together.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            addFilesButton
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: Staged List

    private var stagedListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(queue.stagedURLs.count) file\(queue.stagedURLs.count == 1 ? "" : "s") queued")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear All") { queue.clear() }
                    .font(.footnote)
                    .foregroundColor(.red.opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.inkSurface)

            List {
                ForEach(queue.stagedURLs, id: \.self) { url in
                    HStack(spacing: 12) {
                        Image(systemName: iconFor(url))
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(url.pathExtension.uppercased())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.inkSurface)
                    .listRowSeparatorTint(Color.primary.opacity(0.08))
                }
                .onDelete { queue.remove(at: $0) }
            }
            .listStyle(.plain)

            VStack(spacing: 8) {
                addFilesButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.inkSurface)
        }
    }

    // MARK: Shared Buttons

    private var addFilesButton: some View {
        Button(action: addFiles) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add Folder or Comics")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.inkBlue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(queue.isStagingFiles)
    }



    // MARK: Actions

    private func addFiles() {
        queue.isStagingFiles = true
        ImportCoordinator.present(type: .unified) { urls in
            guard !urls.isEmpty else {
                queue.isStagingFiles = false
                return
            }
            Task.detached(priority: .userInitiated) {
                let result = queue.stageWithDuplicateCheck(urls)
                await MainActor.run {
                    queue.isStagingFiles = false
                    if result.skippedDuplicates > 0 {
                        pendingDuplicates = result.duplicateURLs
                        showDuplicateAlert = true
                    }
                }
            }
        }
    }


    private func importAll() {
        let urls = queue.stagedURLs
        queue.clear()
        
        // Group into series using SeriesNameParser
        let groups = SeriesNameParser.groupIntoSeries(urls)

        // Check each group for series name conflicts with existing library collections
        let existingSeriesNames = Set(conversionManager.collections.map { $0.name.lowercased() })
        let conflicting = groups.filter { group in
            existingSeriesNames.contains(group.seriesName.lowercased())
        }

        if !conflicting.isEmpty {
            pendingConflictGroups = conflicting
            showSeriesConflict = true
            
            // Import non-conflicting groups immediately
            let conflictNames = Set(conflicting.map { $0.seriesName })
            let nonConflicting = groups.filter { !conflictNames.contains($0.seriesName) }
            if !nonConflicting.isEmpty {
                Task { await runImport(groups: nonConflicting) }
            }
        } else {
            dismiss()
            Task { await runImport(groups: groups) }
        }
    }

    private func runImport(groups: [(seriesName: String, urls: [URL])]) async {
        var allURLs: [URL] = []
        var combinedOverrides: [URL: PDFMetadata] = [:]
        
        for group in groups {
            allURLs.append(contentsOf: group.urls)
            for url in group.urls {
                var meta = PDFMetadata(title: url.deletingPathExtension().lastPathComponent)
                meta.series = group.seriesName
                combinedOverrides[url] = meta
            }
        }
        
        await conversionManager.importFilesAsSeries(urls: allURLs, overrides: combinedOverrides)
    }

    private func iconFor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "cbz", "cbr", "cb7": return "doc.zipper"
        case "epub": return "book"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}
