import SwiftUI

struct BackupRestoreView: View {
    var body: some View {
        List {
            Section(header: Text("Backup")) {
                Button("Export Backup File") {
                    // Logic to export JSON data
                }
            }
            
            Section(header: Text("Restore")) {
                Button("Import Backup File") {
                    // Logic to import JSON data
                }
                .foregroundColor(.red)
            }
            
            Section(footer: Text("Backups include your library index, collections, and settings. PDF files are not included in the backup file.")) {}
        }
        .navigationTitle("Backup & Restore")
    }
}
