import SwiftUI
import Combine

// Metadata batch progress view with live countdown and review gate.
// Theme tokens only. TimelineView for live countdown.

struct BatchMetadataFetchView: View {
    @ObservedObject var manager: ConversionManager
    @State private var items: [MetadataBatchItem] = []
    @State private var isPaused: Bool = false
    @State private var resumesAt: Date?
    @State private var isApplying: Bool = false
    @State private var cancellables = Set<AnyCancellable>()

    var doneCount: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var totalCount: Int { items.count }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    if isPaused, let resumeDate = resumesAt {
                        pauseBanner(resumeDate: resumeDate)
                    }

                    headerStats

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { item in
                                itemRow(item)
                            }
                        }
                        .padding()
                    }
                    .opacity(isPaused ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: isPaused)

                    reviewGate
                }
            }
            .navigationTitle("Metadata Fetch")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await subscribeToQueue() }
    }

    // MARK: - Subviews

    private func pauseBanner(resumeDate: Date) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let remaining = max(0, resumeDate.timeIntervalSince(context.date))
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text("Rate limit — resuming in \(Int(remaining))s")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundColor(Color.inkBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.orange)
        }
    }

    private var headerStats: some View {
        HStack(spacing: 20) {
            statBadge(label: "Done", value: doneCount, color: .green)
            statBadge(label: "Failed", value: failedCount, color: Theme.orange)
            statBadge(label: "Total", value: totalCount, color: Color.inkTextSecondary)
        }
        .padding()
        .background(Color.inkSurface)
    }

    private func statBadge(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2.weight(.bold))
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(Color.inkTextSecondary)
        }
    }

    private func itemRow(_ item: MetadataBatchItem) -> some View {
        HStack(spacing: 12) {
            statusIcon(item.status)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.subheadline)
                    .foregroundColor(Color.inkTextPrimary)
                    .lineLimit(1)

                if case .done(let title, let series) = item.status {
                    Text([series, title].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(Color.inkTextSecondary)
                        .lineLimit(1)
                } else if case .failed(let reason) = item.status {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(Theme.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusIcon(_ status: MetadataBatchItemStatus) -> some View {
        Group {
            switch status {
            case .queued:
                Image(systemName: "clock")
                    .foregroundColor(Color.inkTextSecondary)
            case .fetching:
                ProgressView().progressViewStyle(.circular)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.orange)
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundColor(Color.inkTextSecondary)
            }
        }
        .font(.body)
    }

    private var reviewGate: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(doneCount) of \(totalCount) ready to apply")
                    .font(.subheadline)
                    .foregroundColor(Color.inkTextSecondary)
                Spacer()
                Button {
                    Task {
                        isApplying = true
                        await MetadataBatchQueue.shared.applyApproved(to: manager)
                        isApplying = false
                    }
                } label: {
                    if isApplying {
                        ProgressView().progressViewStyle(.circular)
                            .tint(Color.inkBackground)
                    } else {
                        Text("Review & Apply")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Color.inkBackground)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(doneCount > 0 ? Theme.orange : Color.inkTextSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(doneCount == 0 || isApplying)
            }
            .padding()
        }
        .background(Color.inkSurface)
    }

    private func subscribeToQueue() async {
        MetadataBatchQueue.shared.itemsPublisher
            .receive(on: RunLoop.main)
            .sink { newItems in
                self.items = newItems
            }
            .store(in: &cancellables)
    }
}
