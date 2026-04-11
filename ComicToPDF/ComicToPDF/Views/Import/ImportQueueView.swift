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
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if queue.stagedURLs.isEmpty {
                    emptyStateView
                } else {
                    stagedListView
                }

                // Staging-in-progress overlay
                if queue.isStagingFiles {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.white).scaleEffect(1.3)
                        if let progress = queue.stagingProgress {
                            Text("Staging \(progress.current) of \(progress.total) files…")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white)
                        } else {
                            Text("Scanning folder…")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(28)
                    .background(Color(white: 0.15).opacity(0.96))
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
            // Import result summary sheet
            .sheet(isPresented: $showImportSummary) {
                ImportSummaryView(summaries: importSummaries) { failedURLs in
                    // Retry: re-stage failed files
                    queue.forceStage(failedURLs)
                    showImportSummary = false
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
                .foregroundColor(.white)

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
            .background(Color(white: 0.07))

            List {
                ForEach(queue.stagedURLs, id: \.self) { url in
                    HStack(spacing: 12) {
                        Image(systemName: iconFor(url))
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(url.pathExtension.uppercased())
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color(white: 0.1))
                    .listRowSeparatorTint(Color.white.opacity(0.08))
                }
                .onDelete { queue.remove(at: $0) }
            }
            .listStyle(.plain)

            VStack(spacing: 8) {
                addFilesButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.07))
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
            .background(Color.blue)
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
            DispatchQueue.global(qos: .userInitiated).async {
                let result = queue.stageWithDuplicateCheck(urls)
                
                DispatchQueue.main.async {
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
        dismiss()

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
            Task { await runImport(groups: groups) }
        }
    }

    private func runImport(groups: [(seriesName: String, urls: [URL])]) async {
        for group in groups {
            // Build per-file metadata overrides with series name from folder parsing
            var overrides: [URL: PDFMetadata] = [:]
            for url in group.urls {
                var meta = PDFMetadata(title: url.deletingPathExtension().lastPathComponent)
                meta.series = group.seriesName
                overrides[url] = meta
            }
            await conversionManager.importFilesAsSeries(urls: group.urls, overrides: overrides)
        }
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
