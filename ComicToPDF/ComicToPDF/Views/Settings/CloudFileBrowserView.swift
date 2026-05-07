import SwiftUI

// MARK: - Cloud File Browser

/// Premium direct-API cloud browser. Shows files from Dropbox or Google Drive
/// without forcing the user through the generic iOS file picker.
/// Files are streamed on demand — nothing downloads until the user explicitly taps "Add to Library".
struct CloudFileBrowserView: View {
    let provider: CloudBrowserProvider

    @State private var currentFolderID: String? = nil
    @State private var folderStack: [(id: String?, name: String)] = [(nil, "Root")]
    @State private var files: [CloudFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var selectedFiles: Set<String> = []
    @State private var addingToLibrary = false
    @State private var addedCount = 0
    @State private var showingSuccessBanner = false

    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss

    var breadcrumb: String {
        folderStack.map { $0.name }.joined(separator: " › ")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mainList
                if addingToLibrary {
                    loadingOverlay
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .overlay(successBanner, alignment: .bottom)
        }
        .task { await loadDirectory() }
    }

    // MARK: - Views

    @ViewBuilder
    private var mainList: some View {
        VStack(spacing: 0) {
            // Breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(folderStack.enumerated()), id: \.offset) { idx, crumb in
                        Button {
                            navigateToCrumb(at: idx)
                        } label: {
                            Text(crumb.name)
                                .font(.caption.bold())
                                .foregroundColor(idx == folderStack.count - 1 ? .primary : .accentColor)
                        }
                        if idx < folderStack.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(UIColor.secondarySystemBackground))

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Connecting to \(provider.name)…")
                    .padding()
                Spacer()
            } else if let error = errorMessage {
                errorView(error)
            } else if files.isEmpty {
                emptyView
            } else {
                List(files) { file in
                    fileRow(file)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: CloudFile) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(file.isDirectory ? Color.blue.opacity(0.12) : fileColor(file).opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: file.isDirectory ? "folder.fill" : fileIcon(file))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(file.isDirectory ? .blue : fileColor(file))
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if !file.isDirectory {
                    HStack(spacing: 8) {
                        Text(formattedSize(file.size))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(file.modifiedDate, style: .date)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Selection toggle
                Button {
                    toggleSelection(file)
                } label: {
                    Image(systemName: selectedFiles.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(selectedFiles.contains(file.id) ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if file.isDirectory {
                navigateInto(file)
            } else {
                toggleSelection(file)
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No supported files found")
                .font(.headline)
            Text("CBZ, EPUB, ZIP, PDF, and CBR files will appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Connection Failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await loadDirectory() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Adding \(addedCount) file(s) to Library…")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(Material.thick)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var successBanner: some View {
        if showingSuccessBanner {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(addedCount) file(s) added to Library — stream or download anytime.")
                    .font(.subheadline.bold())
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8, y: 4)
            .padding(.horizontal)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if !selectedFiles.isEmpty {
                Button("Add \(selectedFiles.count) to Library") {
                    Task { await addSelectedToLibrary() }
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Navigation

    private func navigateInto(_ file: CloudFile) {
        folderStack.append((file.id, file.name))
        currentFolderID = file.id
        files = []
        Task { await loadDirectory() }
    }

    private func navigateToCrumb(at index: Int) {
        guard index < folderStack.count - 1 else { return }
        folderStack = Array(folderStack.prefix(index + 1))
        currentFolderID = folderStack.last?.id ?? nil
        files = []
        Task { await loadDirectory() }
    }

    // MARK: - Data

    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            let all = try await provider.listDirectory(folderID: currentFolderID)
            // Filter to supported comic/book formats plus directories
            let supported: Set<String> = ["cbz", "cbr", "epub", "zip", "pdf", "cb7", "cbt"]
            let filtered = all.filter { f in
                f.isDirectory || supported.contains(f.name.pathExtension.lowercased())
            }
            await MainActor.run {
                files = filtered.sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                isLoading = false
            }
            Logger.shared.log("CloudBrowser: Loaded \(filtered.count) item(s) from \(provider.name)", category: "Cloud")
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
            Logger.shared.log("CloudBrowser: Failed to load directory — \(error.localizedDescription)", category: "Cloud", type: .error)
        }
    }

    private func toggleSelection(_ file: CloudFile) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
        }
    }

    private func addSelectedToLibrary() async {
        guard !selectedFiles.isEmpty else { return }
        let toAdd = files.filter { selectedFiles.contains($0.id) }
        addedCount = toAdd.count
        addingToLibrary = true

        await MainActor.run {
            for file in toAdd {
                // Create a cloud-sourced ConvertedPDF entry — no local file yet.
                // SourceMode .cloud(provider, remoteID) tells ConversionManager
                // to stream or background-download this file on demand.
                let dummyURL = URL(string: "cloud://\(provider.providerID)/\(file.id)")!
                let cloudPDF = ConvertedPDF(
                    name: file.name,
                    url: dummyURL,
                    pageCount: 0,
                    fileSize: file.size,
                    metadata: PDFMetadata(title: file.name)
                )
                // Register source mode
                var mutable = cloudPDF
                mutable.sourceMode = .cloud(provider: provider.name, remoteID: file.id)
                conversionManager.convertedPDFs.insert(mutable, at: 0)
            }
            conversionManager.saveLibrary()
        }

        addingToLibrary = false
        selectedFiles = []
        withAnimation(.spring()) { showingSuccessBanner = true }
        Logger.shared.log("CloudBrowser: Added \(addedCount) cloud file(s) to Library from \(provider.name)", category: "Cloud", type: .success)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation { showingSuccessBanner = false }
        }
    }

    // MARK: - Helpers

    private func fileIcon(_ file: CloudFile) -> String {
        switch file.name.pathExtension.lowercased() {
        case "epub": return "book.fill"
        case "pdf":  return "doc.richtext.fill"
        default:     return "doc.zipper"
        }
    }

    private func fileColor(_ file: CloudFile) -> Color {
        switch file.name.pathExtension.lowercased() {
        case "epub": return .purple
        case "pdf":  return .red
        default:     return .orange
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_024
        return String(format: "%.0f KB", kb)
    }
}

// MARK: - CloudBrowserProvider — bridges CloudStorageProvider into this View

struct CloudBrowserProvider {
    let name: String
    let providerID: String  // "dropbox" | "googledrive"
    let listDirectory: (_ folderID: String?) async throws -> [CloudFile]

    static var dropbox: CloudBrowserProvider {
        CloudBrowserProvider(
            name: "Dropbox",
            providerID: "dropbox",
            listDirectory: { folderID in
                try await DropboxProvider.shared.listDirectory(folderID: folderID)
            }
        )
    }

    static var googleDrive: CloudBrowserProvider {
        CloudBrowserProvider(
            name: "Google Drive",
            providerID: "googledrive",
            listDirectory: { folderID in
                try await GoogleDriveProvider.shared.listDirectory(folderID: folderID)
            }
        )
    }
}

// MARK: - String extension

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
