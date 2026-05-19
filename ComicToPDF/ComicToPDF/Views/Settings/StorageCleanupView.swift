import SwiftUI

/// Storage cleanup view showing reclaimable files grouped by category.
/// Allows selective deletion with confirmation dialog.
struct StorageCleanupView: View {
    @StateObject private var cleanupManager = SandboxCleanupManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItems: Set<UUID> = []
    @State private var showDeleteConfirmation = false

    private var allItems: [CleanupItem] {
        cleanupManager.scanResults.values.flatMap { $0 }
    }

    private var selectedCleanupItems: [CleanupItem] {
        allItems.filter { selectedItems.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedCleanupItems.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                if cleanupManager.isScanning {
                    scanningView
                } else if cleanupManager.scanResults.isEmpty {
                    emptyStateView
                } else {
                    resultsView
                }
            }
            .navigationTitle("Storage Cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.blue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !selectedItems.isEmpty {
                        Button("Delete (\(selectedItems.count))") {
                            showDeleteConfirmation = true
                        }
                        .foregroundColor(.red)
                        .fontWeight(.semibold)
                    }
                }
            }
            .confirmationDialog(
                "Delete \(selectedItems.count) file\(selectedItems.count == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(cleanupManager.formattedSize(selectedBytes))", role: .destructive) {
                    Task {
                        let items = selectedCleanupItems
                        selectedItems.removeAll()
                        _ = await cleanupManager.delete(items)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will free \(cleanupManager.formattedSize(selectedBytes)). Your original files in Downloads are not affected.")
            }
        }
        .task {
            await cleanupManager.scanForCleanup()
        }
    }

    // MARK: - Subviews

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.orange)
                .scaleEffect(1.3)
            Text("Scanning sandbox…")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("Sandbox is Clean")
                .font(.title3.bold())
                .foregroundColor(.primary)
            Text("No reclaimable files found.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Reclaimable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(cleanupManager.formattedSize(cleanupManager.totalReclaimableBytes))
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                }
                Spacer()
                if !selectedItems.isEmpty {
                    Text("\(selectedItems.count) selected · \(cleanupManager.formattedSize(selectedBytes))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))

            List {
                ForEach(CleanupCategory.allCases, id: \.self) { category in
                    if let items = cleanupManager.scanResults[category], !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                cleanupRow(item)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: category.systemImage)
                                        .foregroundColor(.orange)
                                    Text(category.rawValue)
                                        .font(.subheadline.weight(.semibold))

                                    Spacer()

                                    // Select All / Deselect All
                                    let allSelected = items.allSatisfy { selectedItems.contains($0.id) }
                                    Button(action: {
                                        if allSelected {
                                            for item in items { selectedItems.remove(item.id) }
                                        } else {
                                            for item in items { selectedItems.insert(item.id) }
                                        }
                                    }) {
                                        Text(allSelected ? "Deselect All" : "Select All")
                                            .font(.caption.bold())
                                            .foregroundColor(allSelected ? .secondary : .primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(allSelected ? Color.secondary.opacity(0.2) : Color.blue.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(category.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func cleanupRow(_ item: CleanupItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selectedItems.contains(item.id) ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(cleanupManager.formattedSize(item.fileSizeBytes))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .listRowBackground(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        }
    }
}
