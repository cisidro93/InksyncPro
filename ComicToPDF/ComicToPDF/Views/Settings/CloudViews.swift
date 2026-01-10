import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// MARK: - CLOUD IMPORT/EXPORT VIEWS
// ============================================================================

struct CloudImportView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var importedFiles: [URL] = []
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    Button(action: { showingFilePicker = true }) {
                        HStack(spacing: 16) {
                            ZStack { Circle().fill(Color.blue.opacity(0.2)).frame(width: 50, height: 50); Image(systemName: "folder.fill").font(.title2).foregroundColor(.blue) }
                            VStack(alignment: .leading, spacing: 4) { Text("Browse Files").font(.headline).foregroundColor(.primary); Text("Import from Files, iCloud, Dropbox, Google Drive, etc.").font(.caption).foregroundColor(.secondary) }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                } header: { Text("Import Source") } footer: { Text("The Files app provides access to iCloud Drive and any third-party cloud storage apps you have installed.") }
                Section { ForEach(["CBZ", "CBR", "ZIP"], id: \.self) { format in HStack { Image(systemName: "doc.zipper").foregroundColor(.orange); Text(format); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.green) } } } header: { Text("Supported Formats") }
                if !importedFiles.isEmpty { Section { ForEach(importedFiles, id: \.absoluteString) { url in HStack { Image(systemName: "doc.fill").foregroundColor(.orange); Text(url.lastPathComponent).lineLimit(1); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.green) } } } header: { Text("Ready to Convert") } }
            }
            .navigationTitle("Import from Cloud").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { if !importedFiles.isEmpty { Button("Import \(importedFiles.count)") { completeImport() }.fontWeight(.semibold) } } }
            .sheet(isPresented: $showingFilePicker) { CloudDocumentPicker(selectedFiles: $importedFiles) }
            .alert(alertTitle, isPresented: $showingAlert) { Button("OK") { if alertTitle == "Success" { dismiss() } } } message: { Text(alertMessage) }
        }
    }
    private func completeImport() { alertTitle = "Success"; alertMessage = "Imported \(importedFiles.count) file(s). Go to the Convert tab to convert them to PDF."; showingAlert = true }
}

struct CloudDocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedFiles: [URL]
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { let supportedTypes: [UTType] = [.zip, .archive, UTType(filenameExtension: "cbz") ?? .zip, UTType(filenameExtension: "cbr") ?? .archive]; let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true); picker.allowsMultipleSelection = true; picker.shouldShowFileExtensions = true; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: CloudDocumentPicker
        init(_ parent: CloudDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { let validExtensions = ["cbz", "cbr", "zip", "rar"]; for url in urls { let ext = url.pathExtension.lowercased(); if validExtensions.contains(ext) { if !parent.selectedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }) { parent.selectedFiles.append(url) } } } }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

struct CloudExportView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cloudManager = CloudManager.shared
    let pdfsToExport: [ConvertedPDF]
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var statusMessage = ""
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    Section { ForEach(pdfsToExport) { pdf in HStack { Image(systemName: "doc.fill").foregroundColor(.red); VStack(alignment: .leading) { Text(pdf.name).lineLimit(1); Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary) } } } } header: { Text("Files to Export (\(pdfsToExport.count))") }
                    Section {
                        Button(action: { showingFilePicker = true }) { HStack(spacing: 16) { ZStack { Circle().fill(Color.blue.opacity(0.2)).frame(width: 44, height: 44); Image(systemName: "folder.fill").foregroundColor(.blue) }; VStack(alignment: .leading) { Text("Save to Files").foregroundColor(.primary); Text("Choose location in Files app").font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary) } }
                        if cloudManager.isICloudAvailable { Button(action: exportToICloud) { HStack(spacing: 16) { ZStack { Circle().fill(Color.blue.opacity(0.2)).frame(width: 44, height: 44); Image(systemName: "icloud.fill").foregroundColor(.blue) }; VStack(alignment: .leading) { Text("iCloud Drive").foregroundColor(.primary); Text("Save directly to iCloud").font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary) } } }
                        Button(action: shareFiles) { HStack(spacing: 16) { ZStack { Circle().fill(Color.green.opacity(0.2)).frame(width: 44, height: 44); Image(systemName: "square.and.arrow.up").foregroundColor(.green) }; VStack(alignment: .leading) { Text("Share / Export").foregroundColor(.primary); Text("AirDrop, Email, other apps").font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary) } }
                    } header: { Text("Export Destination") } footer: { Text("Use 'Save to Files' to export to any cloud storage configured in the Files app.") }
                }
                if isExporting { VStack(spacing: 16) { ProgressView(value: exportProgress).progressViewStyle(LinearProgressViewStyle(tint: .blue)); Text(statusMessage).font(.caption).foregroundColor(.secondary) }.padding().background(Color(.secondarySystemBackground)) }
            }
            .navigationTitle("Export to Cloud").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingFilePicker) { ExportDocumentPicker(urls: pdfsToExport.map { $0.url }) { success in if success { alertTitle = "Success"; alertMessage = "Files exported successfully!"; showingAlert = true } } }
            .alert(alertTitle, isPresented: $showingAlert) { Button("OK") { if alertTitle == "Success" { dismiss() } } } message: { Text(alertMessage) }
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

struct ExportDocumentPicker: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true); picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    class Coordinator: NSObject, UIDocumentPickerDelegate { let completion: (Bool) -> Void; init(completion: @escaping (Bool) -> Void) { self.completion = completion }; func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(true) }; func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) } }
}
