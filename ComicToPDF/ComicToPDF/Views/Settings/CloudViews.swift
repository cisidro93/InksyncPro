import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// MARK: - CLOUD IMPORT/EXPORT VIEWS
// ============================================================================

struct CloudImportView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var importedFiles: [URL] = []
    
    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .cornerRadius(6)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(action: { 
                        ImportCoordinator.present(type: .files) { urls in
                            for url in urls where !self.importedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
                                self.importedFiles.append(url)
                            }
                        }
                    }) {
                        HStack(spacing: 16) {
                            settingsIcon("folder.fill", color: .blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Browse Files").font(.headline).foregroundColor(.primary)
                                Text("Import from Files, iCloud, Dropbox, or Google Drive").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text("Import Source") } footer: { Text("The Files app automatically provides access to iCloud Drive and any third-party cloud storage apps you have installed and authenticated.") }
                
                Section {
                    ForEach(["CBZ", "EPUB", "ZIP"], id: \.self) { format in
                        HStack {
                            settingsIcon("doc.zipper", color: .orange)
                            Text(format)
                            Spacer()
                            Image(systemName: "checkmark").foregroundColor(.green).font(.caption.bold())
                        }
                    }
                } header: { Text("Supported Formats") }
                
                if !importedFiles.isEmpty {
                    Section {
                        ForEach(importedFiles, id: \.absoluteString) { url in
                            HStack {
                                settingsIcon("doc.fill", color: .purple)
                                Text(url.lastPathComponent).lineLimit(1)
                            }
                        }
                    } header: { Text("Ready to Convert") }
                }
            }
            .navigationTitle("Import from Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !importedFiles.isEmpty { Button("Import \(importedFiles.count)") { completeImport() }.fontWeight(.semibold) }
                }
            }

            .alert(alertTitle, isPresented: $showingAlert) { Button("OK") { if alertTitle == "Success" { dismiss() } } } message: { Text(alertMessage) }
        }
    }
    
    private func completeImport() {
        alertTitle = "Success"
        alertMessage = "Successfully imported \(importedFiles.count) file(s). Return to the Library to begin processing."
        showingAlert = true
    }
}

struct CloudExportView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cloudManager = CloudManager.shared
    let pdfsToExport: [ConvertedPDF]
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var statusMessage = ""
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .cornerRadius(6)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        ForEach(pdfsToExport) { pdf in
                            HStack {
                                settingsIcon("doc.fill", color: .red)
                                VStack(alignment: .leading) {
                                    Text(pdf.name).lineLimit(1)
                                    Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: { Text("Files Ready to Export (\(pdfsToExport.count))") }
                    
                    Section {
                        Button(action: { showingFilePicker = true }) {
                            HStack(spacing: 16) {
                                settingsIcon("folder.fill", color: .blue)
                                VStack(alignment: .leading) { Text("Save to Files").foregroundColor(.primary); Text("Choose a generic folder location").font(.caption).foregroundColor(.secondary) }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        if cloudManager.isICloudAvailable {
                            Button(action: exportToICloud) {
                                HStack(spacing: 16) {
                                    settingsIcon("icloud.fill", color: .blue)
                                    VStack(alignment: .leading) { Text("iCloud Drive").foregroundColor(.primary); Text("Save directly to your iCloud root").font(.caption).foregroundColor(.secondary) }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        
                        Button(action: shareFiles) {
                            HStack(spacing: 16) {
                                settingsIcon("square.and.arrow.up", color: .green)
                                VStack(alignment: .leading) { Text("Share / AirDrop").foregroundColor(.primary); Text("Export to external apps or contacts").font(.caption).foregroundColor(.secondary) }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: { Text("Export Destination") } footer: { Text("Use 'Save to Files' to export to specifically configured external storage providers.") }
                }
                
                if isExporting {
                    VStack(spacing: 16) {
                        ProgressView(value: exportProgress).progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        Text(statusMessage).font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                }
            }
            .navigationTitle("Export to Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
            .alert(alertTitle, isPresented: $showingAlert) { Button("OK") { if alertTitle == "Success" { dismiss() } } } message: { Text(alertMessage) }
            .onChange(of: showingFilePicker) { _, showing in
                if showing {
                    showingFilePicker = false
                    if let rootVC = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController {
                        ExternalStorageManager.shared.exportMultipleToExternalStorage(fileURLs: pdfsToExport.map { $0.url }, from: rootVC) { success in
                            if success {
                                alertTitle = "Success"
                                alertMessage = "Files exported successfully!"
                                showingAlert = true
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func exportToICloud() {
        isExporting = true
        cloudManager.exportMultipleToICloud(pdfs: pdfsToExport) { progress, message in exportProgress = progress; statusMessage = message } completion: { result in
            isExporting = false
            switch result { case .success(let urls): alertTitle = "Success"; alertMessage = "Exported \(urls.count) file(s) to iCloud Drive"; showingAlert = true; case .failure(let error): alertTitle = "Error"; alertMessage = error.localizedDescription; showingAlert = true }
        }
    }
    
    private func shareFiles() { let urls = pdfsToExport.map { $0.url }; let activityVC = UIActivityViewController(activityItems: urls, applicationActivities: nil); if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let rootViewController = windowScene.windows.first?.rootViewController { if let popover = activityVC.popoverPresentationController { popover.sourceView = rootViewController.view; popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX, y: rootViewController.view.bounds.midY, width: 0, height: 0); popover.permittedArrowDirections = [] }; rootViewController.present(activityVC, animated: true) } }
}
