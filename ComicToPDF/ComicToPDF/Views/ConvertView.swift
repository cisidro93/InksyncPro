import SwiftUI

struct ConvertView: View {
    @State private var isImporting = false
    @State private var selectedFile: URL?
    @State private var isConverting = false
    @State private var progress: Double = 0.0
    @State private var statusMessage = "Ready to Convert"
    
    var body: some View {
        ZStack {
            // Background Gradient
            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                Text("CBZ to PDF")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                // Drop/Select Area
                Button(action: {
                    isImporting = true
                }) {
                    VStack {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                        Text(selectedFile?.lastPathComponent ?? "Select CBZ File")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [10]))
                    )
                }
                .padding()
                
                // Convert Button
                if selectedFile != nil {
                    Button(action: startConversion) {
                        Text(isConverting ? "Converting..." : "Convert to PDF")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .cornerRadius(15)
                    }
                    .padding(.horizontal)
                    .disabled(isConverting)
                }
                
                // Status
                if isConverting || progress > 0 {
                    VStack {
                        ProgressView(value: progress, total: 100)
                            .accentColor(.white)
                        Text(statusMessage)
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding()
                }
                
                Spacer()
            }
            .padding()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data], // Ideally specific UTType
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Security Scoped Access
                    if url.startAccessingSecurityScopedResource() {
                        selectedFile = url
                    }
                }
            case .failure(let error):
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func startConversion() {
        guard let src = selectedFile else { return }
        isConverting = true
        progress = 10
        statusMessage = "Extracting..."
        
        // Simulate Conversion for UI Demo (Since we don't have Python backend yet inside Swift)
        // In real app, we would call a Swift-based ZIP/PDF library.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            progress = 50
            statusMessage = "Generating PDF..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                progress = 100
                isConverting = false
                statusMessage = "Done! Saved to Documents."
            }
        }
    }
}
