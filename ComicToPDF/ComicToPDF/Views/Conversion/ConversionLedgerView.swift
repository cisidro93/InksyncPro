import SwiftUI
import Combine

// Conversion ledger sheet — shows all jobs with status, retry controls.
// Refactored to observe ConversionLedger.shared directly via @ObservedObject.
// Theme tokens only. No hardcoded colors.

struct ConversionLedgerView: View {
    @ObservedObject private var ledger = ConversionLedger.shared
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                let jobs = ledger.allJobs()
                if jobs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(jobs) { job in
                                jobRow(job)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Conversion History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(Color.inkTextSecondary)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    let jobs = ledger.allJobs()
                    if jobs.contains(where: { $0.status == .failed || $0.status == .abandoned }) {
                        Button("Retry All Failed") {
                            ledger.retryFailed(manager: conversionManager)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.orange)
                    }

                    Button("Clear Done") {
                        ledger.clearCompleted()
                    }
                    .foregroundColor(Color.inkTextSecondary)
                }
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
                .foregroundColor(Color.inkTextSecondary)
            Text("No Conversion History")
                .font(.headline)
                .foregroundColor(Color.inkTextSecondary)
        }
    }

    private func jobRow(_ job: ConversionJobRecord) -> some View {
        HStack(spacing: 12) {
            statusIcon(job.status)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color.inkTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(job.outputFormat)
                        .font(.caption)
                        .foregroundColor(Color.inkTextSecondary)

                    if let reason = job.failureReason {
                        Text("·")
                            .foregroundColor(Color.inkTextSecondary)
                        Text(reason)
                            .font(.caption)
                            .foregroundColor(Theme.orange)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if job.status == .failed || job.status == .abandoned {
                Button("Retry") {
                    ledger.retryJob(job.id, manager: conversionManager)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.orange)
                .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color.inkSurface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusIcon(_ status: ConversionJobStatus) -> some View {
        Group {
            switch status {
            case .queued:
                Image(systemName: "clock")
                    .foregroundColor(Color.inkTextSecondary)
            case .running:
                ProgressView()
                    .progressViewStyle(.circular)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed, .abandoned:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.orange)
            case .retrying:
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundColor(.yellow)
            }
        }
        .font(.title3)
    }
}
