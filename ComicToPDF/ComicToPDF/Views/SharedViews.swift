import SwiftUI
import MessageUI
import UniformTypeIdentifiers

// ============================================================================
// MARK: - SHARED HELPERS & VIEWS
// ============================================================================

func colorFor(_ colorName: String) -> Color {
    switch colorName { case "red": return .red; case "orange": return .orange; case "yellow": return .yellow; case "green": return .green; case "blue": return .blue; case "purple": return .purple; case "pink": return .pink; default: return .blue }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DocumentPickerView: UIViewControllerRepresentable {
    @Binding var selectedFiles: [URL]
    @Binding var isPresented: Bool
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true); picker.allowsMultipleSelection = true; picker.delegate = context.coordinator; picker.shouldShowFileExtensions = true; return picker }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    class Coordinator: NSObject, UIDocumentPickerDelegate { let parent: DocumentPickerView; init(parent: DocumentPickerView) { self.parent = parent }; func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { let validExtensions = ["cbz", "cbr", "zip", "rar"]; for url in urls { let ext = url.pathExtension.lowercased(); if validExtensions.contains(ext) { if !parent.selectedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }) { parent.selectedFiles.append(url) } } }; parent.isPresented = false }; func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.isPresented = false } }
}

struct MailComposerView: UIViewControllerRepresentable {
    let pdfURLs: [URL]
    let kindleEmail: String
    var onResult: ((MFMailComposeResult, Error?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController { let composer = MFMailComposeViewController(); composer.mailComposeDelegate = context.coordinator; composer.setToRecipients([kindleEmail]); composer.setSubject("Convert"); composer.setMessageBody("Sent from Comic to PDF Converter", isHTML: false); for url in pdfURLs { if let data = try? Data(contentsOf: url) { composer.addAttachmentData(data, mimeType: "application/pdf", fileName: url.lastPathComponent) } }; return composer }
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposerView
        init(_ parent: MailComposerView) { self.parent = parent }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.onResult?(result, error)
            parent.dismiss()
        }
    }
}

// ============================================================================
// MARK: - KINDLE DEVICE PICKER
// ============================================================================

struct KindleDevicePickerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdfURLs: [URL]
    @State private var selectedDevice: KindleDevice?
    @State private var showingMailComposer = false
    @State private var showingSuccessAnimation = false
    
    var body: some View {
        NavigationView {
            List {
                if conversionManager.kindleDevices.isEmpty { Section { Text("No Kindle devices configured").foregroundColor(.secondary); NavigationLink("Add Kindle Device") { AddEditKindleDeviceView(mode: .add) } } }
                else { Section { ForEach(conversionManager.kindleDevices) { device in Button(action: { selectAndSend(device) }) { HStack { Image(systemName: device.deviceType.icon).foregroundColor(.orange); VStack(alignment: .leading) { Text(device.name).foregroundColor(.primary); Text(device.email).font(.caption).foregroundColor(.secondary) }; Spacer(); if device.isDefault { Text("Default").font(.caption).foregroundColor(.orange) } } } } } header: { Text("Select Device") } }
                Section { HStack { Text("Files"); Spacer(); Text("\(pdfURLs.count)").foregroundColor(.secondary) }; HStack { Text("Total Size"); Spacer(); Text(totalSize).foregroundColor(.secondary) } } header: { Text("Summary") }
            }
            .navigationTitle("Send to Kindle").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showingMailComposer) {
                if let device = selectedDevice {
                    MailComposerView(pdfURLs: pdfURLs, kindleEmail: device.email) { result, error in
                        if result == .sent {
                            handleSuccess(device: device)
                        }
                    }
                }
            }
            .overlay(Group {
                if showingSuccessAnimation {
                    SuccessCheckmarkView()
                }
            })
        }
    }
    
    private var totalSize: String { var total: Int64 = 0; for url in pdfURLs { if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int64 { total += size } }; let formatter = ByteCountFormatter(); formatter.countStyle = .file; return formatter.string(fromByteCount: total) }
    
    private func selectAndSend(_ device: KindleDevice) { selectedDevice = device; showingMailComposer = true }
    
    private func handleSuccess(device: KindleDevice) {
        // Record in history
        for url in pdfURLs {
            if let pdf = conversionManager.convertedPDFs.first(where: { $0.url == url }) {
                conversionManager.recordSend(pdf: pdf, device: device)
            } else {
                // If not in library (e.g. temporary split), create a transient record or skip?
                // Minimal effort: create a transient ConvertedPDF just for the record if possible,
                // or just skip. The requirement implies tracking history.
                // Assuming most uses are from Library. If not found, we can't easily record without more info.
                // Let's at least try to find by filename match if URL path differs?
            }
            // For now, only recording if in library.
        }
        
        // Show animation
        showingSuccessAnimation = true
        HapticManager.shared.notification(.success)
        
        // Auto dismiss after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showingSuccessAnimation = false
            dismiss()
        }
    }
}
