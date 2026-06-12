import SwiftUI

struct LinkedLibrarySettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject var appSettings = AppSettingsManager.shared
    @ObservedObject var driveMonitor = DriveMonitor.shared
    @ObservedObject private var scanner = LinkedLibraryScanner.shared

    @State private var isLinkingDrive = false
    @State private var isRelinkingDrive: AppSettingsManager.LinkedDriveEntry? = nil
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private static let syncFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Form {
            // MARK: Explanation Banner
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Read files directly from external storage or cloud providers — without copying them to your device.", systemImage: "externaldrive.connected.to.line.below.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Label("Works with USB drives, Dropbox, iCloud Drive, Google Drive, and any other iOS Files provider.", systemImage: "cloud")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // MARK: Linked Folders
            Section(header: Text("Linked Folders")) {
                if appSettings.linkedDrives.isEmpty {
                    HStack {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .foregroundColor(.secondary)
                        Text("No folders linked yet.")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                } else {
                    ForEach(appSettings.linkedDrives) { drive in
                        driveRow(drive)
                    }
                }
            }

            // MARK: Status Messages
            if let success = successMessage {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .foregroundColor(.green)
                            .font(.callout)
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                    Button("Dismiss") { errorMessage = nil }
                        .font(.callout)
                }
            }

            // MARK: Link Button
            Section {
                Button(action: { linkNewFolders() }) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(isLinkingDrive ? Color.orange.opacity(0.15) : Color.blue.opacity(0.12))
                                .frame(width: 36, height: 36)
                            if isLinkingDrive {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.orange)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title3)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(isLinkingDrive ? "Linking Folder…" : "Link External Folder")
                                .fontWeight(.semibold)
                            if isLinkingDrive, !scanner.scanStatus.isEmpty {
                                Text(scanner.scanStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("USB drives, Dropbox, iCloud, Google Drive…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .disabled(isLinkingDrive)
            }

            // MARK: How It Works
            Section(header: Text("How It Works")) {
                VStack(alignment: .leading, spacing: 10) {
                    howItWorksRow(icon: "1.circle", text: "For USB drives: connect via a USB-C hub or Lightning adapter and open the Files app to verify it appears.")
                    howItWorksRow(icon: "2.circle", text: "For Dropbox / iCloud / Google Drive: install the app and enable it in Files → Browse → Edit.")
                    howItWorksRow(icon: "3.circle", text: "Tap \"Link External Folder\" and navigate to your comics folder in the picker. Tap Open.")
                    howItWorksRow(icon: "4.circle", text: "InksyncPro indexes your files instantly — nothing is copied to your device. Comics are streamed on demand.")
                    howItWorksRow(icon: "5.circle", text: "If a link expires, tap the Re-link button next to the folder to refresh without losing your library data.")
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .navigationTitle("Linked Library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            LinkedLibraryScanner.shared.conversionManager = conversionManager
        }
    }

    // MARK: - Drive Row

    @ViewBuilder
    private func driveRow(_ drive: AppSettingsManager.LinkedDriveEntry) -> some View {
        let connected = driveMonitor.isConnected(driveID: drive.id)

        HStack(spacing: 12) {
            // Status indicator dot
            ZStack {
                Circle()
                    .fill(connected ? Color.green.opacity(0.15) : Color.red.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: connected ? "externaldrive.fill" : "externaldrive.badge.exclamationmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(connected ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(drive.displayName)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(connected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(connected ? .green : .secondary)

                    Text("·")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("\(drive.fileCount) files")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let synced = drive.lastSyncedDate {
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Synced \(Self.syncFormatter.localizedString(for: synced, relativeTo: Date()))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if drive.isReadOnly {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 10) {
                if connected {
                    Button(action: {
                        Task { await LinkedLibraryScanner.shared.syncDrive(drive) }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Sync — scan for new files added to this folder")
                } else {
                    // Re-link: refresh the bookmark without wiping records
                    Button(action: {
                        relinkFolder(drive)
                    }) {
                        Image(systemName: "link.badge.plus")
                            .foregroundColor(.orange)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(isLinkingDrive)
                    .help("Re-link — pick the folder again to refresh the connection")
                }
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removeDrive(drive)
            } label: {
                Label("Unlink", systemImage: "trash")
            }
        }
    }

    // MARK: - How It Works Row

    @ViewBuilder
    private func howItWorksRow(icon: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        } icon: {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .font(.caption)
        }
    }

    // MARK: - Actions

    private func linkNewFolders() {
        errorMessage = nil
        successMessage = nil
        isLinkingDrive = true

        let manager = conversionManager
        LinkedLibraryScanner.shared.conversionManager = manager

        FolderLinkCoordinator.present { urls in
            guard !urls.isEmpty else {
                Task { @MainActor in self.isLinkingDrive = false }
                return
            }

            Task { @MainActor in
                let scanner = LinkedLibraryScanner.shared
                scanner.conversionManager = manager

                var linked = 0
                var totalFiles = 0

                for url in urls {
                    do {
                        let entry = try await scanner.linkDrive(
                            folderURL: url,
                            displayName: url.lastPathComponent
                        )
                        linked += 1
                        totalFiles += entry.fileCount
                    } catch {
                        self.errorMessage = "Failed to link \"\(url.lastPathComponent)\": \(error.localizedDescription)"
                    }
                }

                self.isLinkingDrive = false

                if linked > 0 {
                    if totalFiles == 0 {
                        self.errorMessage = "Folder\(linked > 1 ? "s" : "") linked but no comic files were found inside. Make sure you selected the folder containing your .cbz / .pdf / .epub files."
                    } else {
                        let folderLabel = linked == 1 ? "\"\(urls.first?.lastPathComponent ?? "Folder")\"" : "\(linked) folders"
                        self.successMessage = "Linked \(folderLabel) — \(totalFiles) comic\(totalFiles == 1 ? "" : "s") found."
                        Task {
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            self.successMessage = nil
                        }
                    }
                }
            }
        }
    }

    private func relinkFolder(_ drive: AppSettingsManager.LinkedDriveEntry) {
        errorMessage = nil
        isLinkingDrive = true
        let manager = conversionManager
        LinkedLibraryScanner.shared.conversionManager = manager

        FolderLinkCoordinator.present { urls in
            guard let url = urls.first else {
                Task { @MainActor in self.isLinkingDrive = false }
                return
            }
            Task { @MainActor in
                do {
                    try await LinkedLibraryScanner.shared.relinkDrive(drive, newFolderURL: url)
                    self.successMessage = "Re-linked \"\(url.lastPathComponent)\" successfully."
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        self.successMessage = nil
                    }
                } catch {
                    self.errorMessage = "Re-link failed: \(error.localizedDescription)"
                }
                self.isLinkingDrive = false
            }
        }
    }

    private func removeDrive(_ drive: AppSettingsManager.LinkedDriveEntry) {
        // unlinkDrive calls saveLibrary() internally, which fires the @Published
        // objectWillChange pipeline automatically — no manual send() needed.
        LinkedLibraryScanner.shared.unlinkDrive(drive)
    }
}
