import SwiftUI

/// Sheet that presents each conflicting series group with options to
/// "Add to Existing Series" or "Create New Series".
struct SeriesConflictView: View {
    let conflictingGroups: [(seriesName: String, urls: [URL])]
    let onAddToExisting: ((seriesName: String, urls: [URL])) -> Void
    let onCreateNew: ((seriesName: String, urls: [URL])) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var resolvedIndices: Set<Int> = []

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                if resolvedIndices.count == conflictingGroups.count {
                    // All resolved
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.green)
                        Text("All Conflicts Resolved")
                            .font(.title3.bold())
                            .foregroundColor(.primary)
                    }
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s
                            dismiss()
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            Text("These series names already exist in your library.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                                .padding(.top, 12)

                            ForEach(Array(conflictingGroups.enumerated()), id: \.offset) { index, group in
                                if !resolvedIndices.contains(index) {
                                    conflictGroupCard(group: group, index: index)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Series Conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Skip All") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func conflictGroupCard(group: (seriesName: String, urls: [URL]), index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "books.vertical.fill")
                    .foregroundColor(.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.seriesName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("\(group.urls.count) file\(group.urls.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: {
                    onAddToExisting(group)
                    withAnimation { _ = resolvedIndices.insert(index) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                        Text("Add to Existing")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button(action: {
                    onCreateNew(group)
                    withAnimation { _ = resolvedIndices.insert(index) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                        Text("Create New")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}
