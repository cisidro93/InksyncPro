import SwiftUI
import MessageUI

struct DualExportView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @Environment(\.presentationMode) var presentationMode
    
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    
    @State private var showingShareSheet = false
    @State private var showingMailView = false
    @State private var showingMailAlert = false
    @AppStorage("hasSeenKFXInstructions") private var hasSeenKFXInstructions = false
    @State private var showingKFXInstructions = false
    @State private var exportURL: URL?
    @State private var navigateToSync = false
    @State private var isProcessing = false
    @State private var mailResult: Result<MFMailComposeResult, Error>? = nil
    
    var body: some View {
        NavigationView {
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
                .background(Color(.secondarySystemBackground))
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
                    .background(Color(.secondarySystemBackground))
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
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                // Option C: Export for Kindle (KFX)
                Button {
                    handleKFXExport()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.system(size: 30))
                            .foregroundStyle(.purple)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export for Kindle (KFX)")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Bypass firmware 5.19.2 sideloading bugs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
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
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                }
                
                if isProcessing {
                    ProgressView("Preparing file...")
                        .padding()
                }
                
                Spacer()
                
                // Hidden Navigation handled by navigationDestination
            }
            .navigationDestination(isPresented: $navigateToSync) {
                WiFiView()
            }
            .padding()
            .navigationTitle("Export Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
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
            .sheet(isPresented: $showingKFXInstructions) {
                KFXInstructionCardView {
                    showingShareSheet = true
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
    
    private func handleKFXExport() {
        isProcessing = true
        Task {
            let url = await conversionManager.exportForKFX(pdf)
            await MainActor.run {
                self.exportURL = url
                self.isProcessing = false
                if url != nil {
                    if !self.hasSeenKFXInstructions {
                        self.showingKFXInstructions = true
                    } else {
                        self.showingShareSheet = true
                    }
                }
            }
            if let safeURL = url {
                Logger.shared.log("Exported for KFX: \(safeURL.lastPathComponent)", category: "Export", type: .success)
            }
        }
    }
}

struct KFXInstructionCardView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("hasSeenKFXInstructions") private var hasSeenKFXInstructions = false
    var onShare: () -> Void
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("What's Next?")
                        .font(.largeTitle.bold())
                    
                    Text("Your comic has been packaged into an **.inksync** file. To complete the transfer to your Kindle, follow these steps on your Mac or PC:")
                        .font(.callout)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        InstructionStep(number: 1, title: "Unzip the .inksync file", description: "Treat it like a normal ZIP file and extract its contents to a folder.")
                        InstructionStep(number: 2, title: "Install Requirements", description: "Ensure you have **Kindle Previewer 3** and **Calibre** (with the KFX Output Plugin) installed.")
                        InstructionStep(number: 3, title: "Run the Script", description: "Open the extracted folder. On Mac, run `convert.sh` in Terminal. On Windows, double-click `convert.bat`.")
                        InstructionStep(number: 4, title: "Transfer to Kindle", description: "Connect your Kindle via USB and copy the resulting **.kfx** file into the 'documents' folder.")
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    
                    Button(action: {
                        hasSeenKFXInstructions = true
                        dismiss()
                        // Small delay to allow sheet to dismiss before presenting ShareSheet
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            onShare()
                        }
                    }) {
                        Text("Share Package")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    .padding(.top, 10)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

struct InstructionStep: View {
    let number: Int
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.blue))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                // Provide text styling fallback for basic markdown
                if #available(iOS 15.0, *) {
                    Text(try! AttributedString(markdown: description))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
