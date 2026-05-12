import SwiftUI

/// Post-import summary sheet showing results per series.
/// Displays success counts, failed files with retry option, and a global retry button.
struct ImportSummaryView: View {
    let summaries: [ImportSummary]
    let onRetry: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    private var allFailedURLs: [URL] {
        summaries.flatMap { $0.failedURLs }
    }

    private var hasFailures: Bool {
        !allFailedURLs.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Header summary
                        headerSection

                        // Per-series results
                        ForEach(summaries) { summary in
                            seriesRow(summary)
                        }

                        // Retry all button
                        if hasFailures {
                            Button(action: {
                                onRetry(allFailedURLs)
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                    Text("Retry All Failed (\(allFailedURLs.count))")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Import Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.blue)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerSection: some View {
        let totalSuccess = summaries.reduce(0) { $0 + $1.successCount }
        let totalFailed = allFailedURLs.count

        VStack(spacing: 8) {
            Image(systemName: hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(hasFailures ? .orange : .green)

            Text(hasFailures ? "Import Complete with Errors" : "Import Complete")
                .font(.title3.bold())
                .foregroundColor(.primary)

            HStack(spacing: 16) {
                Label("\(totalSuccess) imported", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundColor(.green)
                if totalFailed > 0 {
                    Label("\(totalFailed) failed", systemImage: "xmark")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func seriesRow(_ summary: ImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: summary.failedURLs.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(summary.failedURLs.isEmpty ? .green : .orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.seriesName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    if summary.failedURLs.isEmpty {
                        Text("\(summary.successCount) files imported")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(summary.successCount) imported, \(summary.failedURLs.count) failed")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
            }

            // Show failed filenames
            if !summary.failedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.failedURLs, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.badge.ellipsis")
                                .font(.caption2)
                                .foregroundColor(.red.opacity(0.7))
                            Text(url.lastPathComponent)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Retry") {
                                onRetry([url])
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(14)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}
