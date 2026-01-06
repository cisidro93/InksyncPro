import SwiftUI

struct PanelExtractionView: View {
    let sourceImage: UIImage
    @Binding var isPresented: Bool
    @State private var extractedImages: [UIImage] = []
    @State private var isProcessing = false
    @State private var mode: PanelExtractor.ExtractionMode = .automatic
    
    var body: some View {
        NavigationView {
            VStack {
                if extractedImages.isEmpty {
                    Image(uiImage: sourceImage)
                        .resizable()
                        .scaledToFit()
                        .overlay(isProcessing ? ProgressView() : nil)
                } else {
                    List(extractedImages, id: \.self) { img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                    }
                }
            }
            .navigationTitle("Extract Panels")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Extract") {
                        extract()
                    }
                    .disabled(isProcessing)
                }
            }
        }
    }
    
    func extract() {
        isProcessing = true
        Task {
            // ✅ Fix: Use the method that returns UIImages
            let images = try? await PanelExtractor.extractPanels(from: sourceImage, mode: mode)
            await MainActor.run {
                self.extractedImages = images ?? []
                self.isProcessing = false
            }
        }
    }
}
