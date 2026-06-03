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
    @State private var selectedFiles: Set<String> = []       // individual file IDs
    @State private var selectedFolders: Set<String> = []     // folder IDs for bulk-add
    @State private var addingToLibrary = false
    @State private var addedCount = 0
    @State private var scanningFolderName: String? = nil     // shows during recursive scan
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
            .background(Color.inkSurface.opacity(0.4))

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
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listRowBackground(Color.inkSurface.opacity(0.4))
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
                if file.isDirectory {
                    Text("Tap folder icon to browse · tap \u{2295} to add all")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
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
                // Folder row: checkbox on left, navigate chevron on right
                HStack(spacing: 10) {
                    // Folder select toggle — does NOT navigate
                    Button {
                        toggleFolderSelection(file)
                    } label: {
                        Image(systemName: selectedFolders.contains(file.id)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(selectedFolders.contains(file.id) ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    // Navigate into folder
                    Button {
                        navigateInto(file)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // File selection toggle
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
                if let folderName = scanningFolderName {
                    Text("Scanning \"\(folderName)\"…")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    if addedCount > 0 {
                        Text("\(addedCount) files found")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    Text("Adding \(addedCount) file(s) to Library…")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                }
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
            let totalSelected = selectedFiles.count + selectedFolders.count
            if totalSelected > 0 {
                Button {
                    Task { await addSelectedToLibrary() }
                } label: {
                    if selectedFolders.isEmpty {
                        Text("Add \(selectedFiles.count) File\(selectedFiles.count == 1 ? "" : "s")")
                    } else if selectedFiles.isEmpty {
                        Text("Add \(selectedFolders.count) Folder\(selectedFolders.count == 1 ? "" : "s")")
                    } else {
                        Text("Add \(totalSelected) Items")
                    }
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
            let all = try await provider.listDirectory(currentFolderID)
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

    private func toggleFolderSelection(_ folder: CloudFile) {
        if selectedFolders.contains(folder.id) {
            selectedFolders.remove(folder.id)
        } else {
            selectedFolders.insert(folder.id)
        }
    }

    private func addSelectedToLibrary() async {
        guard !selectedFiles.isEmpty || !selectedFolders.isEmpty else { return }
        addingToLibrary = true
        var allFilesToAdd: [CloudFile] = []

        // 1. Direct file selections
        allFilesToAdd.append(contentsOf: files.filter { selectedFiles.contains($0.id) })

        // 2. Recursive folder enumeration
        let folderItems = files.filter { selectedFolders.contains($0.id) }
        for folder in folderItems {
            await MainActor.run { 
                scanningFolderName = folder.name
                addedCount = 0 
            }
            do {
                let folderFiles = try await provider.listAllFiles(folder.id) { @Sendable count in
                    Task { @MainActor in self.addedCount = count }
                }
                allFilesToAdd.append(contentsOf: folderFiles)
                Logger.shared.log(
                    "CloudBrowser: scanned folder \"\(folder.name)\" → \(folderFiles.count) file(s)",
                    category: "Cloud"
                )
            } catch {
                Logger.shared.log(
                    "CloudBrowser: failed to scan folder \"\(folder.name)\": \(error.localizedDescription)",
                    category: "Cloud", type: .error
                )
            }
        }

        // Deduplicate (same file ID selected directly AND found inside a folder)
        var seen = Set<String>()
        let deduped = allFilesToAdd.filter { seen.insert($0.id).inserted }

        addedCount = deduped.count
        await MainActor.run { scanningFolderName = nil }

        var newCloudPDFs: [ConvertedPDF] = []
        await MainActor.run {
            for file in deduped {
                let dummyURL = URL(string: "cloud://\(provider.providerID)/\(file.id)") ?? URL(fileURLWithPath: "/")
                var cloudPDF = ConvertedPDF(
                    name: file.name,
                    url: dummyURL,
                    pageCount: 0,
                    fileSize: file.size,
                    metadata: PDFMetadata(title: file.name)
                )
                cloudPDF.sourceMode = .cloud(provider: provider.name, remoteID: file.id)
                conversionManager.convertedPDFs.insert(cloudPDF, at: 0)
                newCloudPDFs.append(cloudPDF)
            }
            conversionManager.saveLibrary()
        }

        // Kick off asynchronous cover extraction for the newly linked files
        Task {
            await CloudCoverExtractor.shared.extract(for: newCloudPDFs)
        }

        addingToLibrary = false
        selectedFiles = []
        selectedFolders = []
        withAnimation(.spring()) { showingSuccessBanner = true }
        Logger.shared.log(
            "CloudBrowser: Added \(addedCount) cloud file(s) from \(provider.name) (incl. folder contents)",
            category: "Cloud", type: .success
        )

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
    let listDirectory: @Sendable (_ folderID: String?) async throws -> [CloudFile]
    /// Recursively lists all supported files inside a folder (for bulk-add).
    let listAllFiles: @Sendable (_ folderID: String, _ onProgress: (@Sendable (Int) -> Void)?) async throws -> [CloudFile]

    /// The official brand icon image name in Assets.xcassets.
    /// Use with .renderingMode(.original) to preserve brand colours.
    var iconAssetName: String {
        switch providerID {
        case "dropbox":     return "dropbox_icon"
        default:            return "icloud"
        }
    }

    static var dropbox: CloudBrowserProvider {
        CloudBrowserProvider(
            name: "Dropbox",
            providerID: "dropbox",
            listDirectory: { @Sendable folderID in
                try await DropboxProvider.shared.listDirectory(folderID: folderID)
            },
            listAllFiles: { @Sendable folderID, onProgress in
                try await DropboxProvider.shared.listAllFiles(inFolderID: folderID, onProgress: onProgress)
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

// MARK: - CloudBrowserPickerView
// Smart entry point surfaced by the "Cloud" action pill in the library header.
// - If only Dropbox is connected → goes straight to Dropbox browser
// - If only Google Drive is connected → goes straight to Drive browser
// - If both are connected → shows a provider picker
// - If neither is connected → shows an onboarding prompt linking to Settings

struct CloudBrowserPickerView: View {
    @ObservedObject private var dropbox = DropboxProvider.shared
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if dropbox.isConnected {
            // Single provider — present browser immediately
            CloudFileBrowserView(provider: .dropbox)
                .environmentObject(conversionManager)
        } else {
            // Nothing connected — onboarding prompt
            NavigationStack {
                VStack(spacing: 28) {
                    Spacer()
                    Image(systemName: "cloud.slash.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    VStack(spacing: 12) {
                        Text("No Cloud Accounts Connected")
                            .font(.title2.bold())
                        Text("Connect Dropbox or Google Drive in Settings to stream and import comics directly — no file picker required.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Button {
                        dismiss()
                        // Post notification so settings can deep-link to Cloud Storage
                        NotificationCenter.default.post(name: NSNotification.Name("OpenCloudSettings"), object: nil)
                    } label: {
                        Label("Connect in Settings", systemImage: "gear")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .navigationTitle("Cloud Storage")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }



