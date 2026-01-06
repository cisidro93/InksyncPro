import SwiftUI

struct PageManagerView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var images: [UIImage] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Extracting Pages...")
            } else if images.isEmpty {
                Text("No images found.")
                    .foregroundColor(.secondary)
            } else {
                contentView
            }
        }
        .navigationTitle("Page Manager")
        .task {
            loadImages()
        }
    }
    
    // ✅ Fix: Extracted complex logic to separate property
    private var contentView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                ForEach(0..<images.count, id: \.self) { index in
                    VStack {
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                            .cornerRadius(8)
                        Text("Page \(index + 1)")
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
    }
    
    private func loadImages() {
        Task {
            do {
                // Use stubbed method
                let extracted = try await conversionManager.extractImages(from: pdf.url) { _ in }
                await MainActor.run {
                    self.images = extracted
                    self.isLoading = false
                }
            } catch {
                await MainActor.run { isLoading = false }
            }
        }
    }
}
