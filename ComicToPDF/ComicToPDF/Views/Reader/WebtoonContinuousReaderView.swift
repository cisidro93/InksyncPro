import SwiftUI
import UIKit

// MARK: - Virtualized Webtoon Continuous Reader View

/// High-performance continuous vertical reader for webtoons and manhwa.
/// Renders images with zero vertical spacing, lazily decodes visible slices,
/// and dynamically unloads off-screen slices > 2 viewports away to eliminate memory pressure.
public struct WebtoonContinuousReaderView: UIViewRepresentable {
    let pageURLs: [URL]
    @Binding var currentPageIndex: Int
    var isAutoScrolling: Bool = false
    var autoScrollSpeed: Double = 60.0 // px/sec
    var onTapCenter: () -> Void
    var onReachEnd: (() -> Void)? = nil
    
    public init(
        pageURLs: [URL],
        currentPageIndex: Binding<Int>,
        isAutoScrolling: Bool = false,
        autoScrollSpeed: Double = 60.0,
        onTapCenter: @escaping () -> Void,
        onReachEnd: (() -> Void)? = nil
    ) {
        self.pageURLs = pageURLs
        self._currentPageIndex = currentPageIndex
        self.isAutoScrolling = isAutoScrolling
        self.autoScrollSpeed = autoScrollSpeed
        self.onTapCenter = onTapCenter
        self.onReachEnd = onReachEnd
    }
    
    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.decelerationRate = .normal
        scrollView.backgroundColor = .black
        
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 0
        container.alignment = .fill
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(container)
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])
        
        context.coordinator.setup(scrollView: scrollView, container: container, urls: pageURLs)
        
        // Single tap gesture
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        scrollView.addGestureRecognizer(tapGesture)
        
        return scrollView
    }
    
    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateAutoScroll(isActive: isAutoScrolling, speed: autoScrollSpeed)
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    public static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    
    // MARK: - Coordinator
    
    public final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: WebtoonContinuousReaderView
        weak var scrollView: UIScrollView?
        weak var container: UIStackView?
        
        private var imageViews: [UIImageView] = []
        private var pageURLs: [URL] = []
        private var loadTasks: [Int: Task<Void, Never>] = [:]
        private var displayLink: CADisplayLink?
        private var isAutoScrolling = false
        private var scrollSpeed: Double = 60.0
        
        // Dynamic In-Memory Cache (capacity capped at 12 slices)
        private let imageCache = NSCache<NSNumber, UIImage>()
        
        init(parent: WebtoonContinuousReaderView) {
            self.parent = parent
            self.imageCache.countLimit = 12
            self.imageCache.totalCostLimit = 64 * 1024 * 1024 // 64MB
        }
        
        func setup(scrollView: UIScrollView, container: UIStackView, urls: [URL]) {
            self.scrollView = scrollView
            self.container = container
            self.pageURLs = urls
            
            // Build placeholder image views
            for (index, url) in urls.enumerated() {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.backgroundColor = .black
                iv.tag = index
                
                // Intrinsic size estimation
                let heightConstraint = iv.heightAnchor.constraint(equalToConstant: UIScreen.main.bounds.height * 0.8)
                heightConstraint.priority = .defaultLow
                heightConstraint.isActive = true
                
                container.addArrangedSubview(iv)
                imageViews.append(iv)
            }
            
            // Initial viewport slice loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.updateVisibleSlices()
            }
        }
        
        // MARK: - Auto-Scrolling Engine
        
        func updateAutoScroll(isActive: Bool, speed: Double) {
            self.isAutoScrolling = isActive
            self.scrollSpeed = speed
            
            if isActive {
                if displayLink == nil {
                    displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLinkStep))
                    displayLink?.add(to: .main, forMode: .common)
                }
            } else {
                displayLink?.invalidate()
                displayLink = nil
            }
        }
        
        @objc private func handleDisplayLinkStep() {
            guard let sv = scrollView, isAutoScrolling else { return }
            let delta = scrollSpeed / 60.0
            let newY = sv.contentOffset.y + delta
            let maxOffset = sv.contentSize.height - sv.bounds.height
            
            if newY >= maxOffset {
                sv.setContentOffset(CGPoint(x: 0, y: max(0, maxOffset)), animated: false)
                updateAutoScroll(isActive: false, speed: scrollSpeed)
                parent.onReachEnd?()
            } else {
                sv.setContentOffset(CGPoint(x: 0, y: newY), animated: false)
            }
        }
        
        // MARK: - Virtualized Visible Slice Loading & Memory Eviction
        
        private func updateVisibleSlices() {
            guard let sv = scrollView else { return }
            let visibleRect = sv.bounds
            let viewportHeight = visibleRect.height
            
            // Active threshold: 2 viewports above and below
            let activeTop = max(0, visibleRect.minY - (viewportHeight * 2.0))
            let activeBottom = visibleRect.maxY + (viewportHeight * 2.0)
            
            for (index, iv) in imageViews.enumerated() {
                let ivFrame = iv.frame
                let isNearViewport = ivFrame.intersects(CGRect(x: 0, y: activeTop, width: sv.bounds.width, height: activeBottom - activeTop))
                
                if isNearViewport {
                    if iv.image == nil && loadTasks[index] == nil {
                        loadImageSlice(for: index)
                    }
                } else {
                    // Evict slice from memory if > 2 viewports away
                    if iv.image != nil {
                        loadTasks[index]?.cancel()
                        loadTasks.removeValue(forKey: index)
                        iv.image = nil
                    }
                }
            }
            
            // Track active page index at screen center
            let midY = visibleRect.midY
            for (index, iv) in imageViews.enumerated() {
                if iv.frame.contains(CGPoint(x: visibleRect.midX, y: midY)) {
                    if parent.currentPageIndex != index {
                        parent.currentPageIndex = index
                    }
                    break
                }
            }
        }
        
        private func loadImageSlice(for index: Int) {
            guard index < pageURLs.count else { return }
            let url = pageURLs[index]
            
            if let cached = imageCache.object(forKey: NSNumber(value: index)) {
                imageViews[index].image = cached
                adjustImageViewHeight(for: imageViews[index], with: cached)
                return
            }
            
            loadTasks[index] = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                var decodedImage: UIImage? = nil
                
                autoreleasepool {
                    if let data = try? Data(contentsOf: url),
                       let sourceImage = UIImage(data: data) {
                        decodedImage = sourceImage
                    }
                }
                
                guard let img = decodedImage, !Task.isCancelled else { return }
                
                await MainActor.run {
                    self.imageCache.setObject(img, forKey: NSNumber(value: index))
                    if index < self.imageViews.count {
                        let iv = self.imageViews[index]
                        iv.image = img
                        self.adjustImageViewHeight(for: iv, with: img)
                    }
                    self.loadTasks.removeValue(forKey: index)
                }
            }
        }
        
        private func adjustImageViewHeight(for imageView: UIImageView, with image: UIImage) {
            guard let sv = scrollView, sv.bounds.width > 0 else { return }
            let aspect = image.size.height / max(1, image.size.width)
            let targetHeight = sv.bounds.width * aspect
            
            for constraint in imageView.constraints where constraint.firstAttribute == .height {
                constraint.constant = targetHeight
                constraint.priority = .required
            }
        }
        
        // MARK: - UIScrollViewDelegate
        
        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisibleSlices()
        }
        
        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if isAutoScrolling {
                updateAutoScroll(isActive: false, speed: scrollSpeed)
            }
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            if isAutoScrolling {
                updateAutoScroll(isActive: false, speed: scrollSpeed)
            } else {
                parent.onTapCenter()
            }
        }
        
        func cleanup() {
            displayLink?.invalidate()
            displayLink = nil
            for (_, task) in loadTasks {
                task.cancel()
            }
            loadTasks.removeAll()
            imageCache.removeAllObjects()
        }
    }
}
