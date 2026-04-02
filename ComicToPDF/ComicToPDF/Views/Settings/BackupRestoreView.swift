import SwiftUI
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var backupDocument: BackupDocument?
    @State private var importError: String?
    @State private var showingAlert = false
    @State private var showingSuccess = false
    
    var body: some View {
        List {
            Section(header: Text("Backup")) {
                Button(action: prepareBackup) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export Backup File")
                    }
                }
            }
            
            Section(header: Text("Restore")) {
                Button(action: { showingImporter = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import Backup File")
                    }
                }
                .foregroundColor(.blue) // Changed from red for better UX unless dangerous
            }
            
            Section(footer: Text("Backups include your library index, collections, and settings. PDF files are not included in the backup file.")) {}
        }
        .navigationTitle("Backup & Restore")
        .fileExporter(isPresented: $showingExporter, document: backupDocument, contentType: .json, defaultFilename: "InksyncPro_Backup.json") { result in
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                 switch result {
                 case .success:
                     HapticManager.shared.notification(.success)
                 case .failure(let error):
                     importError = error.localizedDescription
                     showingAlert = true
                 }
             }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                importBackup(from: url)
            case .failure(let error):
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    importError = error.localizedDescription
                    showingAlert = true
                }
            }
        }
        .alert("Status", isPresented: $showingAlert) { Button("OK", role: .cancel) { } } message: { Text(importError ?? "Unknown error") }
        .overlay(Group { if showingSuccess { SuccessCheckmarkView() } })
    }
    
    func prepareBackup() {
        let data = conversionManager.createBackupData()
        backupDocument = BackupDocument(data: data)
        showingExporter = true
    }
    
    func importBackup(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                importError = "Permission denied to read backup file."
                showingAlert = true
            }
            return
        }
        
        Task.detached(priority: .userInitiated) {
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                var rawData: Data?
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { safeURL in
                    rawData = try? Data(contentsOf: safeURL)
                }
                
                guard let data = rawData else { throw CocoaError(.fileReadUnknown) }
                let backup = try JSONDecoder().decode(BackupData.self, from: data)
                
                // Enforce 0.5s native modal teardown window
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                await MainActor.run {
                    self.conversionManager.restoreFromBackup(backup)
                    self.showingSuccess = true
                    HapticManager.shared.notification(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.showingSuccess = false }
                }
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    self.importError = "Import failed: \(error.localizedDescription)"
                    self.showingAlert = true
                }
            }
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: BackupData
    
    init(data: BackupData) {
        self.data = data
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.data = try JSONDecoder().decode(BackupData.self, from: data)
        } else {
             throw CocoaError(.fileReadCorruptFile)
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(self.data)
        return FileWrapper(regularFileWithContents: data)
    }
}
