import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - Staged URL Manager

/// Accumulates comic file URLs before the user commits to "Import All".
/// Survives sheet dismissal so users can add from multiple locations.
class ImportQueueManager: ObservableObject {
    static let shared = ImportQueueManager()
    private init() {}

    @Published var stagedURLs: [URL] = []
    @Published var isStagingFiles: Bool = false

    func stage(_ urls: [URL]) {
        let deduped = urls.filter { new in
            !stagedURLs.contains { $0.lastPathComponent == new.lastPathComponent }
        }
        stagedURLs.append(contentsOf: deduped)
    }

    func remove(at offsets: IndexSet) { stagedURLs.remove(atOffsets: offsets) }
    func clear() { stagedURLs.removeAll() }
}

// MARK: - Import Queue View

struct ImportQueueView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var queue = ImportQueueManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false

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
                        Text("Scanning folder…")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
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
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let folderURL = urls.first else { return }
                    queue.isStagingFiles = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let accessing = folderURL.startAccessingSecurityScopedResource()
                        let found = ImportCoordinator.processFolderSpiderSync(url: folderURL)
                        if accessing { folderURL.stopAccessingSecurityScopedResource() }
                        DispatchQueue.main.async {
                            queue.isStagingFiles = false
                            if !found.isEmpty { queue.stage(found) }
                        }
                    }
                case .failure(let error):
                    Logger.shared.log("FileImporter error: \(error.localizedDescription)", category: "System", type: .error)
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
        Button(action: { showFilePicker = true }) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add Files")
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

    private func importAll() {
        let urls = queue.stagedURLs
        queue.clear()
        dismiss()
        Task { await conversionManager.importFilesAsSeries(urls: urls) }
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
