import SwiftUI

struct LinkedLibrarySettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject var appSettings = AppSettingsManager.shared
    @ObservedObject var driveMonitor = DriveMonitor.shared
    
    @State private var isLinkingDrive = false
    @State private var errorMessage: String?
    
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
                                    Text("\\(drive.fileCount) files")
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
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            Section {
                Button(action: {
                    linkNewDrive()
                }) {
                    HStack {
                        Image(systemName: "externaldrive.badge.plus")
                        Text("Link External USB Drive")
                    }
                }
            }
        }
        .navigationTitle("Linked Library")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func linkNewDrive() {
        errorMessage = nil
        FolderLinkCoordinator.present { url in
            guard let url = url else { return }
            
            Task {
                do {
                    // LinkedLibraryScanner.linkDrive handles bookmark creation, file scanning,
                    // thumbnail generation, and addLinkedDrive persistence all atomically.
                    // The FolderLinkCoordinator already called startAccessingSecurityScopedResource
                    // before handing us the URL, giving us the temporary access window we need.
                    let _ = try await LinkedLibraryScanner.shared.linkDrive(
                        folderURL: url,
                        displayName: url.lastPathComponent
                    )
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to link drive: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func removeDrive(_ drive: AppSettingsManager.LinkedDriveEntry) {
        appSettings.removeLinkedDrive(drive)
        // Clean up its files from the local conversion manager
        conversionManager.convertedPDFs.removeAll { pdf in
            if case .linked(let bookmark) = pdf.sourceMode {
                return bookmark == drive.volumeBookmarkData
            }
            return false
        }
        conversionManager.saveLibrary()
        conversionManager.objectWillChange.send()
    }
}
