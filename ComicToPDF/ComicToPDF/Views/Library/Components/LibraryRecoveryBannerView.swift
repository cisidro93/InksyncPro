import SwiftUI

struct LibraryRecoveryBannerView: View {
    @ObservedObject var quarantineManager = QuarantineManager.shared
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var showingDetails = false
    
    var body: some View {
        if quarantineManager.isVaultActive {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud Recovery Detected")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        let mb = Double(quarantineManager.quarantinedTotalSize) / 1024 / 1024
                        Text("We trapped \(quarantineManager.quarantinedFileCount) files (\(String(format: "%.1f", mb)) MB) from a previous iCloud session.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    Button {
                        withAnimation { showingDetails.toggle() }
                    } label: {
                        Image(systemName: showingDetails ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                            .foregroundColor(.orange)
                            .imageScale(.large)
                    }
                }
                
                if showingDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When you reinstalled InksyncPro, Apple's iCloud Drive automatically redownloaded files you had previously generated. To prevent these 'ghost files' from silently polluting your new library, we have quarantined them.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                        
                        HStack(spacing: 16) {
                            Button {
                                quarantineManager.purgeVault()
                            } label: {
                                Spacer()
                                Label("Execute Purge", systemImage: "trash.fill")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(10)
                            
                            Button {
                                Task { await quarantineManager.restoreVault(manager: conversionManager) }
                            } label: {
                                Spacer()
                                Label("Restore Normal", systemImage: "arrow.uturn.backward.circle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(10)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground).opacity(0.7))
            .cornerRadius(16)
            .shadow(color: .orange.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.scale.combined(with: .opacity))
        }
    }
}
