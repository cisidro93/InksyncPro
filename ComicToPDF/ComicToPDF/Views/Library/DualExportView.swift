import SwiftUI

struct DualExportView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showingShareSheet = false
    @State private var exportURL: URL?
    @State private var navigateToSync = false
    @State private var isProcessing = false
    
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
                
                if isProcessing {
                    ProgressView("Preparing file...")
                        .padding()
                }
                
                Spacer()
                
                // Hidden Navigation
                NavigationLink(destination: KindleSyncView(), isActive: $navigateToSync) { EmptyView() }
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
        }
    }
    
    private func handleCloudExport() {
        isProcessing = true
        // Small delay to let UI update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let url = conversionManager.exportForCloudSync(pdf)
            self.exportURL = url
            self.isProcessing = false
            self.showingShareSheet = true
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
}
