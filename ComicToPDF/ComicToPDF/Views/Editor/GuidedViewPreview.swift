import SwiftUI

struct GuidedViewPreview: View {
    let image: UIImage
    let panels: [CGRect]
    @Environment(\.dismiss) var dismiss
    
    @State private var currentIndex: Int = 0
    @State private var viewSize: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if panels.isEmpty {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("No panels detected")
                        .foregroundColor(.white)
                        .padding()
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                GeometryReader { geo in
                    ZStack {
                        // Current Panel
                        if panels.indices.contains(currentIndex) {
                            let rect = panels[currentIndex]
                            let panelImage = cropImage(image, to: rect)
                            
                            Image(uiImage: panelImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .transition(.opacity)
                                .id(currentIndex) // Force transition
                        }
                        
                        // Tap Areas
                        HStack(spacing: 0) {
                            Color.black.opacity(0.001) // Left Tap (Prev)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if currentIndex > 0 {
                                            currentIndex -= 1
                                        } else {
                                            // Maybe loop or bump?
                                        }
                                    }
                                }
                            
                            Color.black.opacity(0.001) // Right Tap (Next)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if currentIndex < panels.count - 1 {
                                            currentIndex += 1
                                        } else {
                                            // End of preview
                                            dismiss()
                                        }
                                    }
                                }
                        }
                    }
                    .onAppear {
                        viewSize = geo.size
                    }
                }
                
                // Overlay Info
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                    Spacer()
                    HStack {
                        Text("Panel \(currentIndex + 1) / \(panels.count)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .statusBar(hidden: true)
    }
    
    func cropImage(_ image: UIImage, to normalizedRect: CGRect) -> UIImage {
        // Convert normalized rect to pixel rect
        // Input rect is Top-Left origin (0,0 is top-left)
        // CIImage/CGImage usually expects 0,0 at bottom-left, OR top-left depending on context.
        // Let's assume standard CGImage cropping (Top-Left for CGRect in UIKit context usually works if we use UIGraphics)
        
        let width = image.size.width
        let height = image.size.height
        
        let cropRect = CGRect(
            x: normalizedRect.minX * width,
            y: normalizedRect.minY * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        )
        
        // Use CGImage for cropping
        // bounds check
        if cropRect.width <= 0 || cropRect.height <= 0 || cropRect.isInfinite || cropRect.isEmpty {
             Logger.shared.log("Invalid crop rect: \(cropRect)", category: "ERROR")
             return image
        }
        
        // Ensure within image bounds
        _ = CGRect(origin: .zero, size: image.size)
        // If cropRect is outside image bounds, CGImage.cropping handles it by returning partial or nil?
        // Let's be safe.
        let intersection = cropRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        
        if let cgImage = image.cgImage?.cropping(to: intersection) {
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        } else {
            Logger.shared.log("CGImage crop failed", category: "ERROR")
        }
        
        return image // Fallback
    }
}
