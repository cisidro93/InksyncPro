import SwiftUI

struct ReaderChrome: View {
    let pdf: ConvertedPDF
    let title: String
    let pageText: String
    @Binding var isVisible: Bool
    
    // Actions
    var onBack: () -> Void
    var onEInkSend: () -> Void
    var onBookmark: () -> Void
    var onAnnotationsToggle: () -> Void
    var onSettingsToggle: () -> Void
    
    // Scrubber
    @Binding var currentProgress: Double
    let totalPages: Int
    // Optional TTS
    var hasTTS: Bool = false
    var isSpeaking: Bool = false
    var onTTSToggle: (() -> Void)? = nil
    
    // Optional KOReader PDF Tools
    var isPDF: Bool = false
    var isReflowActive: Bool = false
    var onCropToggle: (() -> Void)? = nil
    var onReflowToggle: (() -> Void)? = nil
    
    // Image Enhancement
    var isEnhanced: Bool = false
    var onEnhanceToggle: (() -> Void)? = nil
    
    var body: some View {
        VStack {
            // Top Bar
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                
                Spacer()
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                
                Spacer()
                    if isPDF {
                        Button(action: { onReflowToggle?() }) {
                            Image(systemName: "text.alignleft")
                                .font(.body.weight(.semibold))
                                .foregroundColor(isReflowActive ? .black : .white)
                                .padding(12)
                                .background(isReflowActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                        }
                        
                        Button(action: { onCropToggle?() }) {
                            Image(systemName: "crop")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    if onEnhanceToggle != nil {
                        Button(action: { onEnhanceToggle?() }) {
                            Image(systemName: "wand.and.stars")
                                .font(.body.weight(.semibold))
                                .foregroundColor(isEnhanced ? .black : .white)
                                .padding(12)
                                .background(isEnhanced ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                        }
                    }
                    Button(action: onAnnotationsToggle) {
                        Image(systemName: "note.text")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button(action: onSettingsToggle) {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            .padding(.horizontal)
            .padding(.top, 8)
            
            Spacer()
            
            // Bottom Bar
            VStack(spacing: 12) {
                // Scrubber Area
                HStack {
                    Text("1")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    
                    Slider(value: $currentProgress, in: 0...1)
                        .accentColor(.blue)
                    
                    Text("\(totalPages)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal)
                
                HStack {
                    Button(action: onBookmark) {
                        Image(systemName: "bookmark")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    
                    if hasTTS {
                        Button(action: { onTTSToggle?() }) {
                            Image(systemName: isSpeaking ? "stop.circle.fill" : "headphones")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(isSpeaking ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                        }
                    }
                    
                    Spacer()
                    
                    Text(pageText)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    
                    Spacer()
                    
                    Button(action: onEInkSend) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .background(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(.ultraThinMaterial)
                }
                .edgesIgnoringSafeArea(.bottom)
            )
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }
}
