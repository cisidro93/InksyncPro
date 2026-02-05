import SwiftUI
import CoreImage.CIFilterBuiltins

struct KindleSyncView: View {
    @EnvironmentObject var wifiServer: WiFiServer
    @State private var qrCodeImage: UIImage?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    
                    Text("Kindle Direct Sync")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Transfer comics to your Kindle without using Amazon Cloud, preserving all layout metadata.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top)
                
                if wifiServer.isRunning, let serverURL = wifiServer.serverURL {
                    // Kindle Route
                    let kindleURL = serverURL + "/kindle"
                    
                    VStack(spacing: 20) {
                        // Step 1
                        HStack(alignment: .top) {
                            Image(systemName: "1.circle.fill")
                            VStack(alignment: .leading) {
                                Text("Open Experimental Browser")
                                    .font(.headline)
                                Text("On your Kindle, tap Menu > Web Browser.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        // Step 2
                        HStack(alignment: .top) {
                            Image(systemName: "2.circle.fill")
                            VStack(alignment: .leading) {
                                Text("Enter this URL")
                                    .font(.headline)
                                
                                Text(kindleURL)
                                    .font(.system(.title3, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundStyle(.blue)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 4)
                                
                                // ✅ Fix: Show PIN for Authentication
                                Text("PIN: \(wifiServer.securityCode)")
                                    .font(.system(.title3, design: .monospaced))
                                    .fontWeight(.heavy)
                                    .foregroundStyle(.green)
                                    .padding(.top, 4)
                                    .textSelection(.enabled)
                                
                                Text("Or scan QR code (Kindle Scribe)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    
                    // QR Code
                    if let qr = qrCodeImage {
                        Image(uiImage: qr)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding()
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                            .overlay(
                                Image(systemName: "ipad.and.iphone") // Central Logo Placeholder
                                    .foregroundStyle(.black)
                                    .padding(4)
                                    .background(.white)
                                    .clipShape(Circle())
                            )
                    }
                    
                } else {
                    // Server Off State
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Wi-Fi Server is Stopped")
                            .font(.headline)
                        
                        Button("Start Server") {
                            wifiServer.start()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                // Tips
                VStack(alignment: .leading, spacing: 10) {
                    Text("Troubleshooting")
                        .font(.caption)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    
                    Label("Ensure both devices are on the same Wi-Fi.", systemImage: "wifi")
                    Label("Disable VPN/Private Relay if connection fails.", systemImage: "network.badge.shield.half.filled")
                    Label("Kindle must support EPUB or PDF.", systemImage: "doc.text")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if wifiServer.isRunning {
                generateQRCode()
            }
        }
        .onChange(of: wifiServer.serverURL) { _ in
            generateQRCode()
        }
    }
    
    private func generateQRCode() {
        guard let serverURL = wifiServer.serverURL else { return }
        let kindleURL = serverURL + "/kindle"
        
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(kindleURL.utf8)
        filter.correctionLevel = "M" // Medium error correction
        
        if let outputImage = filter.outputImage {
            // Scale up to avoid blur
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)
            
            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                self.qrCodeImage = UIImage(cgImage: cgImage)
            }
        }
    }
}
