import SwiftUI
import MessageUI
import UIKit

struct DualExportView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    
    @State private var showingShareSheet = false
    @State private var showingMailView = false
    @State private var showingMailAlert = false
    @State private var showingSaveToFiles = false

    @State private var exportURL: URL?
    @State private var navigateToSync = false
    @State private var isProcessing = false
    @State private var mailResult: Result<MFMailComposeResult, Error>? = nil
    @State private var saveToFilesSuccessToast = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    // Header
                VStack(spacing: 8) {
                    Text("Export '\(pdf.name)'")
                        .font(.headline)
                    Text("Choose an export method")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)
                
                // Export Summary
                VStack(alignment: .leading, spacing: 6) {
                    Text("Export Settings Summary")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        Text("Format: \(settingsManager.conversionSettings.outputFormat.rawValue)")
                        Spacer()
                        Text("Quality: \(settingsManager.conversionSettings.compressionQuality.rawValue)")
                    }
                    .font(.caption2)
                    
                    if settingsManager.conversionSettings.optimizeForDevice {
                        Text("Target Device: \(settingsManager.conversionSettings.targetDeviceProfile.rawValue)")
                            .font(.caption2)
                    }
                    if settingsManager.conversionSettings.imageEnhancement.grayscale || settingsManager.conversionSettings.imageEnhancement.autoContrast {
                        Text("Filters: E-Ink Optimized")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding()
                .background(Color.inkSurface.opacity(0.8))
                .cornerRadius(8)
                .cornerRadius(8)
                .padding(.horizontal)
                
                // Option A: Cloud Sync
                Button {
                    handleCloudExport()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 30))
                            .foregroundStyle(.blue)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud Sync (Send to Kindle)")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Standard EPUB. Amazon may strip advanced layout data.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.inkSurface.opacity(0.8))
                    .cornerRadius(12)
                }
                
                // Option B: Local Direct
                Button {
                    handleLocalExport()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "wifi")
                            .font(.system(size: 30))
                            .foregroundStyle(.orange)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local High-Quality")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Best for Guided View. Preserves 1:1 layout via Wi-Fi.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.inkSurface.opacity(0.8))
                    .cornerRadius(12)
                }

                // Option C: Save to Files
                Button {
                    handleSaveToFiles()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.yellow)
                            .frame(width: 40)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Save to Files")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Copy the original file to iCloud Drive, On My iPhone, or any Files location.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.inkSurface.opacity(0.8))
                    .cornerRadius(12)
                }

                // Option D: Email to Kindle
                if !kindleEmail.isEmpty {
                    Button {
                        if MFMailComposeViewController.canSendMail() {
                            handleEmailExport()
                        } else {
                            showingMailAlert = true
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.black)
                                .frame(width: 40)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Email to Kindle")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Send directly to \(kindleEmail)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.inkSurface.opacity(0.8))
                        .cornerRadius(12)
                    }
                }
                
                if isProcessing {
                    ProgressView("Preparing file...")
                        .padding()
                }
                
                Spacer()
                
                }
                .frame(maxWidth: 580)
                .padding()

                // Success toast for Save to Files
                if saveToFilesSuccessToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Saved to Files")
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToSync) {
                WiFiView()
            }
            .padding()
            .navigationTitle("Export Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = exportURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(isPresented: $showingMailView) {
                if let url = exportURL {
                    MailView(
                        subject: "Sent to Kindle: \(pdf.name)",
                        recipients: [kindleEmail],
                        messageBody: "Find your exported comic/manga attached.",
                        isHTML: false,
                        attachments: [((try? Data(contentsOf: url)) ?? Data(), url.pathExtension == "pdf" ? "application/pdf" : "application/epub+zip", url.lastPathComponent)],
                        isShowing: $showingMailView,
                        result: $mailResult
                    )
                }
            }
            .sheet(isPresented: $showingSaveToFiles) {
                if let url = exportURL {
                    DocumentExporterSheet(fileURL: url) { saved in
                        if saved {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                saveToFilesSuccessToast = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                withAnimation { saveToFilesSuccessToast = false }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func handleCloudExport() {
        isProcessing = true
        Task {
            let url = await conversionManager.exportForCloudSync(pdf)
            await MainActor.run {
                self.exportURL = url
                self.isProcessing = false
                self.showingShareSheet = true
            }
            if let safeURL = url {
                Logger.shared.log("Exported for Cloud Sync: \(safeURL.lastPathComponent)", category: "Export", type: .success)
            }
        }
    }
    
    private func handleLocalExport() {
        isProcessing = true
        Task {
            TransferQueueManager.shared.clearQueue()
            TransferQueueManager.shared.stageFile(pdf)
            await MainActor.run {
                self.isProcessing = false
                self.navigateToSync = true
            }
            Logger.shared.log("Staged single file to queue for Local High-Quality Export", category: "Export", type: .success)
        }
    }

    private func handleSaveToFiles() {
        isProcessing = true
        Task {
            do {
                let resolved = try await CloudDownloadManager.shared.resolveLocalURL(for: pdf)
                let localSourceURL = resolved.url
                let needsSourceCleanup = resolved.needsCleanup
                
                let fileManager = FileManager.default
                let tempDir = fileManager.temporaryDirectory
                    .appendingPathComponent("InksyncExport", isDirectory: true)
                try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let destURL = tempDir.appendingPathComponent(pdf.name)
                try? fileManager.removeItem(at: destURL)
                
                let didAccess = localSourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { localSourceURL.stopAccessingSecurityScopedResource() }
                    if needsSourceCleanup { try? fileManager.removeItem(at: localSourceURL) }
                }
                
                try fileManager.copyItem(at: localSourceURL, to: destURL)
                await MainActor.run {
                    self.exportURL = destURL
                    self.isProcessing = false
                    self.showingSaveToFiles = true
                }
                Logger.shared.log("Prepared '\(destURL.lastPathComponent)' for Save to Files export", category: "Export", type: .success)
            } catch {
                Logger.shared.log("Save to Files preparation failed: \(error.localizedDescription)", category: "Export", type: .error)
                await MainActor.run { isProcessing = false }
            }
        }
    }
    
    private func handleEmailExport() {
        isProcessing = true
        Task {
            let url = await conversionManager.exportForCloudSync(pdf)
            await MainActor.run {
                self.exportURL = url
                self.isProcessing = false
                self.showingMailView = true
            }
            if let safeURL = url {
                Logger.shared.log("Exported for Email: \(safeURL.lastPathComponent)", category: "Export", type: .success)
            }
        }
    }
    
}

// MARK: - UIDocumentPickerViewController wrapper for SwiftUI

/// Presents a native "Save to Files" picker using UIDocumentPickerViewController(forExporting:).
/// This is the same API used by every major iOS app (PDF Expert, GoodReader, Books, etc.).
struct DocumentExporterSheet: UIViewControllerRepresentable {
    let fileURL: URL
    var onDismiss: ((_ saved: Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // forExporting: presents the "Save to Files" destination picker.
        // asCopy: false means the system moves the temp file (which we own) into the chosen location.
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDismiss: ((_ saved: Bool) -> Void)?
        init(onDismiss: ((_ saved: Bool) -> Void)?) { self.onDismiss = onDismiss }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss?(true)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss?(false)
        }
    }
}
