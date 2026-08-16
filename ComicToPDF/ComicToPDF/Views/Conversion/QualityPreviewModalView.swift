import SwiftUI
import CoreGraphics

/// Executive Compression Quality Live Preview Modal
/// Features a side-by-side split-curtain slider comparison, 1:1 zoom loupe magnifier,
/// and live size reduction analytics.
struct QualityPreviewModalView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: ConversionSettings
    let sampleImage: UIImage?
    let fileTitle: String
    let totalPageCount: Int
    let totalInputSizeBytes: Int64
    
    @State private var splitOffset: CGFloat = 0.5
    @State private var isLoupeActive: Bool = false
    @State private var loupePosition: CGPoint = CGPoint(x: 150, y: 200)
    @State private var processedImage: UIImage? = nil
    @State private var isProcessing: Bool = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Preset Quick-Compare Bar
                presetSelectorBar
                
                Divider().overlay(Color.primary.opacity(0.1))
                
                // Real-Time Estimated Size Savings Banner
                sizeAnalyticsBanner
                
                // Interactive Split Curtain Canvas
                ZStack {
                    Color(UIColor.systemGroupedBackground)
                        .ignoresSafeArea()
                    
                    if let original = sampleImage {
                        SplitCanvas(
                            original: original,
                            processed: processedImage ?? original,
                            splitOffset: $splitOffset,
                            isLoupeActive: $isLoupeActive,
                            loupePosition: $loupePosition
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No Preview Available")
                                .font(.headline)
                        }
                    }
                    
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(1.2)
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                
                Divider().overlay(Color.primary.opacity(0.1))
                
                // Footnote Controls
                footerBar
            }
            .navigationTitle("Live Quality Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            generatePreview()
        }
        .onChange(of: settings.compressionQuality) { _, _ in
            generatePreview()
        }
        .onChange(of: settings.targetFileSizeMB) { _, _ in
            generatePreview()
        }
    }
    
    // MARK: - Preset Selector Bar
    
    private var presetSelectorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CompressionPreset.allCases) { preset in
                    Button {
                        HapticEngine.light()
                        settings.compressionQuality = preset
                    } label: {
                        HStack(spacing: 4) {
                            Text(preset.rawValue)
                                .font(.subheadline)
                                .fontWeight(settings.compressionQuality == preset ? .bold : .medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(settings.compressionQuality == preset ? Color.blue : Color(UIColor.tertiarySystemFill))
                        .foregroundColor(settings.compressionQuality == preset ? .white : .primary)
                        .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Size Analytics Banner
    
    private var sizeAnalyticsBanner: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ESTIMATED ARCHIVE SIZE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 6) {
                    Text(formattedInputSize)
                        .strikethrough()
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Text(formattedOutputSize)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: "leaf.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("\(savingsPercentage)% Smaller")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .cornerRadius(6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }
    
    // MARK: - Footer Bar
    
    private var footerBar: some View {
        HStack {
            Button {
                HapticEngine.light()
                isLoupeActive.toggle()
            } label: {
                Label(isLoupeActive ? "Hide Loupe" : "100% Magnifier", systemImage: isLoupeActive ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .tint(isLoupeActive ? .blue : .primary)
            
            Spacer()
            
            Text("Drag slider to compare Original vs Compressed")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Calculations & Async Preview Generation
    
    private var totalInputSize: Int64 {
        totalInputSizeBytes > 0 ? totalInputSizeBytes : Int64(max(1, totalPageCount) * 1_500_000)
    }
    
    private var estimatedOutputSizeBytes: Int64 {
        let pages = max(1, totalPageCount)
        switch settings.compressionQuality {
        case .ultra:
            return Int64(Double(totalInputSize) * (settings.outputFormat == .epub ? 1.08 : 1.05))
        case .customTarget:
            let targetBytes = Int64(settings.targetFileSizeMB * 1024 * 1024)
            return min(totalInputSize, targetBytes)
        case .high:
            let base = Int64(pages) * 500_000
            return settings.outputFormat == .epub ? base + 2_000_000 : base
        case .balanced:
            let base = Int64(pages) * 320_000
            return settings.outputFormat == .epub ? base + 2_000_000 : base
        case .compact:
            let base = Int64(pages) * 190_000
            return settings.outputFormat == .epub ? base + 2_000_000 : base
        }
    }
    
    private var formattedInputSize: String {
        let mb = Double(totalInputSize) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    private var formattedOutputSize: String {
        let mb = Double(estimatedOutputSizeBytes) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    private var savingsPercentage: Int {
        guard totalInputSize > 0 else { return 0 }
        let saved = Double(totalInputSize - estimatedOutputSizeBytes) / Double(totalInputSize)
        return max(0, Int(saved * 100))
    }
    
    private func generatePreview() {
        guard let source = sampleImage else { return }
        isProcessing = true
        
        let currentSettings = settings
        Task.detached(priority: .userInitiated) {
            let processed = ImageProcessor.process(image: source, settings: currentSettings) ?? source
            
            // Encode to JPEG at active compression quality to reflect real compression artifacts
            let quality = currentSettings.compressionQuality.value
            let encodedData = processed.jpegData(compressionQuality: quality) ?? Data()
            let finalImage = UIImage(data: encodedData) ?? processed
            
            await MainActor.run {
                self.processedImage = finalImage
                self.isProcessing = false
            }
        }
    }
}

// MARK: - Split Canvas Component

private struct SplitCanvas: View {
    let original: UIImage
    let processed: UIImage
    @Binding var splitOffset: CGFloat
    @Binding var isLoupeActive: Bool
    @Binding var loupePosition: CGPoint
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            ZStack {
                // Right Layer: Processed (Compressed)
                Image(uiImage: processed)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                
                // Left Layer: Original (Clipped to splitOffset)
                Image(uiImage: original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: width * splitOffset)
                            Spacer(minLength: 0)
                        }
                    )
                
                // Labels Badge Overlay
                VStack {
                    HStack {
                        Text("ORIGINAL")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                        
                        Spacer()
                        
                        Text("COMPRESSED")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    .padding(12)
                    Spacer()
                }
                
                // Draggable Split Divider Line
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3)
                    .shadow(radius: 4)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 32, height: 32)
                            .shadow(radius: 4)
                            .overlay(
                                Image(systemName: "line.3.horizontal")
                                    .rotationEffect(.degrees(90))
                                    .font(.caption2)
                                    .foregroundColor(.black)
                            )
                    )
                    .position(x: width * splitOffset, y: height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newOffset = value.location.x / width
                                splitOffset = min(max(newOffset, 0.05), 0.95)
                            }
                    )
                
                // Magnifier Loupe Overlay
                if isLoupeActive {
                    MagnifierLoupe(
                        original: original,
                        processed: processed,
                        position: loupePosition,
                        containerSize: geo.size
                    )
                    .position(loupePosition)
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                loupePosition = val.location
                            }
                    )
                }
            }
        }
    }
}

// MARK: - Magnifier Loupe Component

private struct MagnifierLoupe: View {
    let original: UIImage
    let processed: UIImage
    let position: CGPoint
    let containerSize: CGSize
    
    private let loupeDiameter: CGFloat = 140.0
    private let zoomFactor: CGFloat = 2.5
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
            
            Image(uiImage: processed)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: containerSize.width * zoomFactor, height: containerSize.height * zoomFactor)
                .offset(
                    x: (containerSize.width / 2 - position.x) * zoomFactor,
                    y: (containerSize.height / 2 - position.y) * zoomFactor
                )
        }
        .frame(width: loupeDiameter, height: loupeDiameter)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .shadow(radius: 6)
        )
    }
}
