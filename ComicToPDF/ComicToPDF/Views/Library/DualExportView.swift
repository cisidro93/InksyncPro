import SwiftUI
import MessageUI

struct DualExportView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.presentationMode) var presentationMode
    
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    
    @State private var showingShareSheet = false
    @State private var showingMailView = false
    @State private var showingMailAlert = false
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
                        Text("Format: \(conversionManager.conversionSettings.outputFormat.rawValue)")
                        Spacer()
                        Text("Quality: \(conversionManager.conversionSettings.compressionQuality.rawValue)")
                    }
                    .font(.caption2)
                    
                    if conversionManager.conversionSettings.optimizeForDevice {
                        Text("Target Device: \(conversionManager.conversionSettings.targetDevice.rawValue)")
                            .font(.caption2)
                    }
                    if conversionManager.conversionSettings.imageEnhancement.grayscale || conversionManager.conversionSettings.imageEnhancement.autoContrast {
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
                
                // Option C: Email to Kindle
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
                
                // Hidden Navigation
                NavigationLink(destination: WiFiView(), isActive: $navigateToSync) { EmptyView() }
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
        }
    }
    
    private func handleLocalExport() {
        isProcessing = true
        Task {
            if let hqURL = await conversionManager.exportForLocalSideload(pdf) {
                await MainActor.run {
                    self.isProcessing = false
                    self.navigateToSync = true
                }
                print("✅ Exported HQ to: \(hqURL.lastPathComponent)")
            } else {
                await MainActor.run {
                    self.isProcessing = false
                }
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
        }
    }
}
