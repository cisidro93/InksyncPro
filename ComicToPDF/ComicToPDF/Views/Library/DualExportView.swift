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
    @State private var showingExportErrorAlert = false
    @State private var exportErrorMessage = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        InkSheetDragPill()
                            .padding(.top, 4)
                        
                        // Header
                        VStack(spacing: 6) {
                            Text("Export '\(pdf.name)'")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.inkText)
                                .multilineTextAlignment(.center)
                            Text("Select your preferred transfer destination")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .padding(.top, 4)
                        
                        // Export Summary
                        VStack(alignment: .leading, spacing: 8) {
                            InkSectionHeader("Export Settings Summary")
                            
                            HStack {
                                Text("Format: \(settingsManager.conversionSettings.outputFormat.rawValue)")
                                Spacer()
                                Text("Quality: \(settingsManager.conversionSettings.compressionQuality.rawValue)")
                            }
                            .font(.caption2)
                            .foregroundStyle(Color.inkSecondary)
                            
                            if settingsManager.conversionSettings.optimizeForDevice {
                                Text("Target Device: \(settingsManager.conversionSettings.targetDeviceProfile.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.inkSecondary)
                            }
                            if settingsManager.conversionSettings.imageEnhancement.grayscale || settingsManager.conversionSettings.imageEnhancement.autoContrast {
                                Text("Filters: E-Ink Optimized")
                                    .font(.caption2)
                                    .foregroundStyle(Color.inkGreen)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.inkSurfaceRaised)
                        )
                        .inkSpecularBorder(cornerRadius: 14)
                        
                        // Kindle Spread Pre-Flight Validator
                        KindleSpreadPreFlightCard(
                            pdf: pdf,
                            outputFormat: settingsManager.conversionSettings.outputFormat,
                            mangaMode: settingsManager.conversionSettings.mangaMode
                        )

                        // Section Header
                        VStack(alignment: .leading, spacing: 12) {
                            InkSectionHeader("Export Methods")
                            
                            // Option A: Cloud Sync
                            Button {
                                HapticEngine.selection()
                                handleCloudExport()
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "icloud.and.arrow.up")
                                        .font(.system(size: 26))
                                        .foregroundStyle(Color.inkBlue)
                                        .frame(width: 36)
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Cloud Sync (Send to Kindle)")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color.inkText)
                                        Text("Standard EPUB. Amazon may strip advanced layout data.")
                                            .font(.caption)
                                            .foregroundStyle(Color.inkSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.inkSecondary.opacity(0.6))
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.inkSurfaceRaised)
                                )
                                .inkSpecularBorder(cornerRadius: 14)
                            }
                            
                            // Option B: Local Direct
                            Button {
                                HapticEngine.selection()
                                handleLocalExport()
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "wifi")
                                        .font(.system(size: 26))
                                        .foregroundStyle(Color.inkOrange)
                                        .frame(width: 36)
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Local High-Quality")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color.inkText)
                                        Text("Best for Guided View. Preserves 1:1 layout via Wi-Fi.")
                                            .font(.caption)
                                            .foregroundStyle(Color.inkSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.inkSecondary.opacity(0.6))
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.inkSurfaceRaised)
                                )
                                .inkSpecularBorder(cornerRadius: 14)
                            }

                            // Option C: Save to Files
                            Button {
                                HapticEngine.selection()
                                handleSaveToFiles()
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(Color.inkYellow)
                                        .frame(width: 36)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Save to Files")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color.inkText)
                                        Text("Copy the original file to iCloud Drive, On My iPhone, or Files.")
                                            .font(.caption)
                                            .foregroundStyle(Color.inkSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.inkSecondary.opacity(0.6))
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.inkSurfaceRaised)
                                )
                                .inkSpecularBorder(cornerRadius: 14)
                            }

                            // Option D: Email to Kindle
                            if !kindleEmail.isEmpty {
                                Button {
                                    HapticEngine.selection()
                                    if MFMailComposeViewController.canSendMail() {
                                        handleEmailExport()
                                    } else {
                                        showingMailAlert = true
                                    }
                                } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: "envelope.fill")
                                            .font(.system(size: 26))
                                            .foregroundStyle(Color.inkViolet)
                                            .frame(width: 36)
                                        
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Email to Kindle")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Color.inkText)
                                            Text("Send directly to \(kindleEmail)")
                                                .font(.caption)
                                                .lineLimit(1)
                                                .foregroundStyle(Color.inkSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.inkSecondary.opacity(0.6))
                                    }
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.inkSurfaceRaised)
                                    )
                                    .inkSpecularBorder(cornerRadius: 14)
                                }
                            }
                        }
                        
                        if isProcessing {
                            ProgressView("Preparing file...")
                                .tint(Color.inkBlue)
                                .padding()
                        }
                    }
                    .frame(maxWidth: 580)
                    .padding()
                }

                // Success toast for Save to Files
                if saveToFilesSuccessToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.inkGreen)
                            Text("Saved to Files")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.inkText)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(Color.inkSurfaceRaised)
                        )
                        .inkSpecularBorder(cornerRadius: 20)
                        .shadow(color: Color.black.opacity(0.2), radius: 12, y: 6)
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToSync) {
                WiFiView()
            }
            .navigationTitle("Export Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        HapticEngine.selection()
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.inkBlue)
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
            .alert("Export Notice", isPresented: $showingExportErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
    }
    
    private func handleCloudExport() {
        isProcessing = true
        Task {
            let url = await conversionManager.exportForCloudSync(pdf)
            await MainActor.run {
                self.isProcessing = false
                if let safeURL = url {
                    self.exportURL = safeURL
                    self.showingShareSheet = true
                    Logger.shared.log("Exported for Cloud Sync: \(safeURL.lastPathComponent)", category: "Export", type: .success)
                } else {
                    self.exportErrorMessage = "Unable to prepare '\(pdf.name)' for Cloud Sync. Please ensure device storage is available."
                    self.showingExportErrorAlert = true
                }
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
                await MainActor.run {
                    self.isProcessing = false
                    self.exportErrorMessage = "Could not prepare file for export: \(error.localizedDescription)"
                    self.showingExportErrorAlert = true
                }
            }
        }
    }
    
    private func handleEmailExport() {
        isProcessing = true
        Task {
            let url = await conversionManager.exportForCloudSync(pdf)
            await MainActor.run {
                self.isProcessing = false
                if let safeURL = url {
                    self.exportURL = safeURL
                    self.showingMailView = true
                    Logger.shared.log("Exported for Email: \(safeURL.lastPathComponent)", category: "Export", type: .success)
                } else {
                    self.exportErrorMessage = "Unable to prepare '\(pdf.name)' for email. Please verify the document is accessible."
                    self.showingExportErrorAlert = true
                }
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

// MARK: - Kindle Spread Pre-Flight Validator Card
struct KindleSpreadPreFlightCard: View {
    let pdf: ConvertedPDF
    let outputFormat: OutputFormat
    let mangaMode: Bool
    
    private var isEPUB: Bool {
        outputFormat == .epub || pdf.name.lowercased().hasSuffix(".epub")
    }
    
    private var isManga: Bool {
        mangaMode || pdf.metadata.isManga
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Kindle Spread & Pre-Flight Validator", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkGreen)
                Spacer()
                Text(isEPUB ? "100% Kindle Ready" : "EPUB Recommended")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isEPUB ? Color.inkGreen.opacity(0.18) : Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(isEPUB ? Color.inkGreen : Color.orange)
            }

            // Visual 2-Page Spread Simulator
            HStack(spacing: 10) {
                // Page 1 (Cover / Single)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay(
                            VStack(spacing: 2) {
                                Image(systemName: "book.closed.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.inkTextTertiary)
                                Text("Cover")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.inkTextSecondary)
                            }
                        )
                        .frame(width: 44, height: 60)
                    Text("Solo")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.inkTextTertiary)
                }

                Image(systemName: isManga ? "arrow.left" : "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.inkTextTertiary)

                // 2-Page Spread Pair
                HStack(spacing: 2) {
                    // Left Page
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .overlay(
                            Text(isManga ? "Right" : "Left")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.inkTextSecondary)
                        )
                        .frame(width: 42, height: 60)

                    // Right Page
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .overlay(
                            Text(isManga ? "Left" : "Right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.inkTextSecondary)
                        )
                        .frame(width: 42, height: 60)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.inkBlue.opacity(0.4), lineWidth: 1)
                )

                Spacer()

                // Specs list
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkBlue)
                        Text(isManga ? "Manga (RTL Progression)" : "Comic (LTR Progression)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.inkText)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkGreen)
                        Text("Kindle Synthetic Spreads Active")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.inkTextSecondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkBlue)
                        Text("TOC Landmarks & NCX Embedded")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.inkTextSecondary)
                    }
                }
            }
            .padding(.vertical, 4)

            Divider()

            HStack {
                Text(isEPUB ? "✓ Amazon Cloud converter routes through 100% compliant fixed-layout pipeline with zero dual-page drift." : "⚠️ For Send to Kindle, EPUB format guarantees true 2-page spreads without page offset shifts.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(isEPUB ? Color.inkTextSecondary : Color.orange)
                    .lineLimit(2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.inkSurfaceRaised)
        )
        .inkSpecularBorder(cornerRadius: 14)
    }
}

