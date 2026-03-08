import SwiftUI

struct IntrinsicAnimation<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
    }
}

// Ensure the name is exactly what we export
public struct ImmersiveConversionOverlay: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdfName: String
    
    // Optional overrides for Queue/Batch modes
    var customProgress: Double? = nil
    var customMessage: String? = nil
    
    // Internal animation state properties
    @State private var pulseIntensity: CGFloat = 0.8
    @State private var rotationDegree: Double = 0.0
    
    // We expect the pipeline steps to be roughly 5 stages.
    var currentStage: String {
        let msg = customMessage ?? conversionManager.statusMessage ?? ""
        if msg.contains("Extracting") || msg.contains("Unzipping") { return "Unpacking Archive" }
        if msg.contains("Detecting") || msg.contains("Vision") { return "AI Panel Extraction" }
        if msg.contains("Resizing") || msg.contains("Optimizing") { return "Optimizing Assets" }
        if msg.contains("Constructing EPUB") || msg.contains("Writing") { return "Building EPUB" }
        if msg.contains("Finishing") || msg.contains("Complete") { return "Finalizing" }
        return msg.isEmpty ? "Initializing..." : msg
    }
    
    public var body: some View {
        ZStack {
            // Background blur and dim
            Color.black.opacity(0.85)
                .ignoresSafeArea()
            
            // Pulsing background glow
            Circle()
                .fill(LinearGradient(colors: [Theme.blue.opacity(0.4), Color.purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .scaleEffect(pulseIntensity)
                .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: pulseIntensity)
                .onAppear { pulseIntensity = 1.2 }
            
            VStack(spacing: 40) {
                // Animated rings
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 8)
                        .frame(width: 120, height: 120)
                    
                    Circle()
                        .trim(from: 0.0, to: customProgress ?? conversionManager.conversionProgress)
                        .stroke(
                            LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: customProgress ?? conversionManager.conversionProgress)
                    
                    // Rotating inner element representing work
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(rotationDegree))
                        .animation(.linear(duration: 8.0).repeatForever(autoreverses: false), value: rotationDegree)
                        .onAppear { rotationDegree = 360 }
                }
                
                // Text Information
                VStack(spacing: 12) {
                    Text(currentStage)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        // Animate text changes
                        .id(currentStage)
                        .transition(.opacity.combined(with: .scale))
                        .animation(.easeInOut, value: currentStage)
                    
                    Text(pdfName)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 40)
                    
                    Text("\(Int((customProgress ?? conversionManager.conversionProgress) * 100))%")
                        .font(.title3.monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.top, 8)
                }
                
                // Detailed sub-status if available
                let activeDetail = customMessage ?? conversionManager.statusMessage
                if let detail = activeDetail, detail != currentStage {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .id(detail)
                        .transition(.opacity)
                }
            }
        }
        // Force rendering over everything
        .zIndex(100)
    }
}
