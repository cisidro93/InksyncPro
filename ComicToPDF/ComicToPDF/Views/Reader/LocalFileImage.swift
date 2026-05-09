import SwiftUI
import UIKit

/// A purely local, OOM-resistant image loader replacing the memory-leaking SwiftUI `AsyncImage`.
/// `AsyncImage` uses URLSession underneath which retains local file uncompressed bitmaps
/// in the global URLCache, guaranteeing Jetsam crashes on Webtoon scrolling.
struct LocalFileImage: View {
    let url: URL
    
    @State private var loadedImage: UIImage? = nil
    @State private var isFailed = false
    
    var body: some View {
        Group {
            if let uiImage = loadedImage {
                ZoomableScrollView {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else if isFailed {
                VStack {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("Decompressed OOM")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
                .background(Color.black.opacity(0.1))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 400)
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onDisappear {
            // Aggressively dump the bitmap from memory when the view scrolls off-screen
            loadedImage = nil
        }
    }
    
    @MainActor
    private func loadImage() async {
        // Offload IO blocking to background thread
        let localURL = url
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: localURL, options: .mappedIfSafe),
                  let image = UIImage(data: data) else {
                // Fallback to absolute path
                return UIImage(contentsOfFile: localURL.path)
            }
            
            // Force synchronous decompression off the main thread to prevent frame dropping
            _ = image.cgImage
            return image
        }.value
        
        // ✅ Apply Advanced Display Filters & Smart Crop Bounds securely on background thread Actor
        if let rawDecoded = decoded {
            let prefs = EBookPreferences.shared
            let processed = await ReaderImageFilterEngine.shared.process(
                url: localURL,
                image: rawDecoded,
                isSmartCrop: prefs.isSmartCropEnabled,
                contrast: prefs.autoContrastLevel,
                saturation: prefs.saturationLevel,
                warmth: prefs.warmthLevel
            )
            self.loadedImage = processed
        } else {
            self.isFailed = true
        }
    }
}
