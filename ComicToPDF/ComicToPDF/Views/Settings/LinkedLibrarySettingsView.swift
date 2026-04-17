import SwiftUI

struct LinkedLibrarySettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject var appSettings = AppSettingsManager.shared
    @ObservedObject var driveMonitor = DriveMonitor.shared

    @State private var isLinkingDrive = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Linked Library allows you to read your comics directly from an external USB drive (SSD, Flash Drive, etc.) without copying the massive files to your iPad's internal storage.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }

            Section(header: Text("Linked Drives")) {
                if appSettings.linkedDrives.isEmpty {
                    Text("No external drives linked.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(appSettings.linkedDrives) { drive in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(drive.displayName)
                                    .font(.headline)

                                HStack {
                                    Circle()
                                        .fill(driveMonitor.isConnected(driveID: drive.id) ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(driveMonitor.isConnected(driveID: drive.id) ? "Connected" : "Disconnected")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(drive.fileCount) files")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()

                            if driveMonitor.isConnected(driveID: drive.id) {
                                Button(action: {
                                    Task {
                                        await LinkedLibraryScanner.shared.syncDrive(drive)
                                    }
                                }) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .padding(.trailing, 8)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                removeDrive(drive)
                            } label: {
                                Label("Unlink", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if let success = successMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }

            Section {
                Button(action: {
                    linkNewDrive()
                }) {
                    HStack {
                        if isLinkingDrive {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "externaldrive.badge.plus")
                        }
                        Text(isLinkingDrive ? "Linking Drive..." : "Link External USB Drive")
                    }
                }
                .disabled(isLinkingDrive)
            }

            Section(header: Text("How It Works")) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connect your USB drive to your iPad via a USB-C hub or Lightning adapter.", systemImage: "1.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label("Tap \"Link External USB Drive\" and navigate to your comics folder in the Files picker.", systemImage: "2.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label("Tap \"Open\" — Inksync will scan and register your comics without copying them.", systemImage: "3.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label("Your comics appear in the Library. Re-link if the bookmark expires after a long disconnection.", systemImage: "4.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Linked Library")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func linkNewDrive() {
        errorMessage = nil
        successMessage = nil
        isLinkingDrive = true

        FolderLinkCoordinator.present { url in
            guard let url = url else {
                // User cancelled — not an error
                Task { @MainActor in self.isLinkingDrive = false }
                return
            }

            Task {
                do {
                    let entry = try await LinkedLibraryScanner.shared.linkDrive(
                        folderURL: url,
                        displayName: url.lastPathComponent
                    )
                    await MainActor.run {
                        self.isLinkingDrive = false
                        self.successMessage = "Linked \"\(entry.displayName)\" — \(entry.fileCount) comic\(entry.fileCount == 1 ? "" : "s") found."
                        // Auto-clear success message after 5 seconds
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            self.successMessage = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isLinkingDrive = false
                        self.errorMessage = "Failed to link drive: \(error.localizedDescription). Make sure the drive is connected and try tapping 'Link External USB Drive' again."
                    }
                }
            }
        }
    }

    private func removeDrive(_ drive: AppSettingsManager.LinkedDriveEntry) {
        LinkedLibraryScanner.shared.unlinkDrive(drive)
        conversionManager.objectWillChange.send()
    }
}
