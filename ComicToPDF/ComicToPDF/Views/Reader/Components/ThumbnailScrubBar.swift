import SwiftUI
import PDFKit

// MARK: - Low-Memory Thumbnail Cache

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1024 * 1024 // 16MB max
    }
    
    func getThumbnail(for page: PDFPage, index: Int, targetSize: CGSize) -> UIImage? {
        let key = "\(index)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        var generatedImage: UIImage? = nil
        autoreleasepool {
            generatedImage = page.thumbnail(of: targetSize, for: .cropBox)
            if let img = generatedImage {
                cache.setObject(img, forKey: key)
            }
        }
        return generatedImage
    }
    
    func purge() {
        cache.removeAllObjects()
    }
}

// MARK: - Haptic Thumbnail Scrub Rail View

/// High-speed collapsible thumbnail scrub rail with discrete page haptic feedback,
/// low-memory cached mipmaps, and a floating page/chapter preview badge.
struct ThumbnailScrubBar: View {
    let document: PDFDocument?
    let totalPages: Int
    @Binding var currentPageIndex: Int
    var onSelectPage: (Int) -> Void
    var onDismiss: (() -> Void)? = nil
    
    @State private var isScrubbing: Bool = false
    @State private var scrubIndex: Int = 0
    @State private var scrubProgress: CGFloat = 0.0
    @State private var previewThumbnail: UIImage? = nil
    
    init(
        document: PDFDocument?,
        totalPages: Int,
        currentPageIndex: Binding<Int>,
        onSelectPage: @escaping (Int) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.document = document
        self.totalPages = max(1, totalPages)
        self._currentPageIndex = currentPageIndex
        self.onSelectPage = onSelectPage
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - Floating Preview Pill HUD
            if isScrubbing {
                floatingPreviewPill
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
            
            // MARK: - Scrub Ribbon Track
            GeometryReader { geo in
                let availableWidth = geo.size.width
                
                ZStack(alignment: .leading) {
                    // Track Base
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.inkSurface.opacity(0.92))
                        .background(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    
                    // Active Fill Progress
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.inkViolet.opacity(0.35), .inkBlue.opacity(0.35)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(16, availableWidth * CGFloat(scrubIndex) / CGFloat(max(1, totalPages - 1))))
                    
                    // Thumb Handle
                    Circle()
                        .fill(Color.white)
                        .frame(width: isScrubbing ? 22 : 16, height: isScrubbing ? 22 : 16)
                        .shadow(color: Color.black.opacity(0.25), radius: 4, y: 2)
                        .offset(x: max(0, min(availableWidth - 22, (availableWidth - 22) * CGFloat(scrubIndex) / CGFloat(max(1, totalPages - 1)))))
                        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isScrubbing)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing {
                                isScrubbing = true
                                HapticEngine.light()
                            }
                            
                            let ratio = max(0, min(1, value.location.x / availableWidth))
                            let newIndex = Int(round(ratio * CGFloat(totalPages - 1)))
                            
                            if newIndex != scrubIndex {
                                scrubIndex = newIndex
                                HapticEngine.light()
                                loadPreviewThumbnail(for: newIndex)
                            }
                        }
                        .onEnded { value in
                            let ratio = max(0, min(1, value.location.x / availableWidth))
                            let targetPage = Int(round(ratio * CGFloat(totalPages - 1)))
                            
                            onSelectPage(targetPage)
                            currentPageIndex = targetPage
                            
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                isScrubbing = false
                            }
                        }
                )
            }
            .frame(height: 32)
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 8)
        .onAppear {
            scrubIndex = currentPageIndex
        }
        .onChange(of: currentPageIndex) { _, newIndex in
            if !isScrubbing {
                scrubIndex = newIndex
            }
        }
    }
    
    // MARK: - Floating Preview Pill
    
    private var floatingPreviewPill: some View {
        HStack(spacing: 10) {
            if let thumb = previewThumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(scrubIndex + 1) of \(totalPages)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                if let doc = document, let page = doc.page(at: scrubIndex), let label = page.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.inkSurfaceRaised.opacity(0.95).background(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
    }
    
    // MARK: - Thumbnail Preloading
    
    private func loadPreviewThumbnail(for index: Int) {
        guard let doc = document, let page = doc.page(at: index) else { return }
        self.previewThumbnail = ThumbnailCache.shared.getThumbnail(
            for: page,
            index: index,
            targetSize: CGSize(width: 72, height: 96)
        )
    }
}
