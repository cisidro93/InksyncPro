import SwiftUI
import UIKit

// ============================================================================
// WebtoonScrollView
// ============================================================================
// A UIScrollView-backed webtoon reader with:
//   • Pixel-precise auto-scroll driven by CADisplayLink (no jitter)
//   • Configurable scroll speed (px/sec) with a speed-change HUD
//   • Pause-on-tap while auto-scrolling
//   • Vertical scroll offset memory keyed by pdfID (UserDefaults)
//   • Current-page index tracking based on visible image midpoint
// ============================================================================

struct WebtoonScrollView: UIViewRepresentable {
    let pages: [URL]
    @Binding var currentPageIndex: Int
    var pdfID: UUID?
    var isAutoScrolling: Bool
    var scrollSpeed: Double         // points per second
    var onCenterTap: () -> Void
    var onEndReached: (() -> Void)? = nil

    // MARK: - Position Persistence Key

    private var savedOffsetKey: String {
        "webtoon_offset_\(pdfID?.uuidString ?? "unknown")"
    }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate              = context.coordinator
        sv.showsVerticalScrollIndicator   = false
        sv.showsHorizontalScrollIndicator = false
        sv.alwaysBounceVertical  = true
        sv.decelerationRate      = .normal
        sv.backgroundColor       = .black

        // Stack all page images vertically
        let stack = UIStackView()
        stack.axis      = .vertical
        stack.spacing   = 0
        stack.alignment = .fill
        context.coordinator.stack = stack

        sv.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: sv.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sv.frameLayoutGuide.trailingAnchor),
        ])

        // Populate images lazily
        context.coordinator.populate(stack: stack, pages: pages, scrollView: sv)

        // Tap gesture for pause / chrome toggle
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        sv.addGestureRecognizer(tap)

        context.coordinator.scrollView = sv
        context.coordinator.parentView = self

        // Restore saved offset
        let savedY = UserDefaults.standard.double(forKey: savedOffsetKey)
        if savedY > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                sv.setContentOffset(CGPoint(x: 0, y: savedY), animated: false)
            }
        }

        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parentView = self
        context.coordinator.updateAutoScroll(isActive: isAutoScrolling, speed: scrollSpeed, sv: sv)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Cancel the display link and all in-flight image loads so the Coordinator
    /// can be released when the scroll view is torn down.
    /// Without this, CADisplayLink(target: coordinator) holds a strong reference
    /// and keeps the Coordinator (and its closure-captured SwiftUI state) alive
    /// past the view's lifetime → EXC_BAD_ACCESS on the next page-change callback.
    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parentView: WebtoonScrollView
        weak var scrollView: UIScrollView?
        weak var stack: UIStackView?

        private var displayLink: CADisplayLink?
        private var imageViews: [UIImageView] = []
        private var loadTasks: [Int: Task<Void, Never>] = [:]
        private var hasReportedEnd = false

        init(_ parent: WebtoonScrollView) { self.parentView = parent }

        // MARK: - Populate

        func populate(stack: UIStackView, pages: [URL], scrollView: UIScrollView) {
            for (index, url) in pages.enumerated() {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFit
                iv.backgroundColor = .black
                iv.tag = index

                // Aspect-ratio placeholder: assume ~1.5:1 height/width for portrait comics
                let ph = UIView()
                ph.backgroundColor = .clear
                ph.heightAnchor.constraint(
                    equalTo: ph.widthAnchor, multiplier: 1.42
                ).isActive = true
                ph.addSubview(iv)
                iv.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    iv.topAnchor.constraint(equalTo: ph.topAnchor),
                    iv.bottomAnchor.constraint(equalTo: ph.bottomAnchor),
                    iv.leadingAnchor.constraint(equalTo: ph.leadingAnchor),
                    iv.trailingAnchor.constraint(equalTo: ph.trailingAnchor),
                ])

                stack.addArrangedSubview(ph)
                imageViews.append(iv)

                // 1. Fast aspect ratio metadata extraction (prevents layout jitter during scroll)
                Task.detached(priority: .userInitiated) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                          let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
                          let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat,
                          width > 0 else { return }
                    
                    let ratio = height / width
                    await MainActor.run {
                        if let superview = iv.superview {
                            for constraint in superview.constraints where constraint.firstAttribute == .height && constraint.relation == .equal {
                                constraint.isActive = false
                            }
                            superview.heightAnchor.constraint(equalTo: superview.widthAnchor, multiplier: ratio).isActive = true
                        }
                    }
                }

                // 2. Async image decode — top 5 pages eagerly, rest lazily
                if index < 5 { loadImage(at: index, url: url, into: iv) }
            }
        }

        private func loadImage(at index: Int, url: URL, into iv: UIImageView) {
            guard loadTasks[index] == nil else { return }
            loadTasks[index] = Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let img  = UIImage(data: data) else { return }

                let isSmartCrop = UserDefaults.standard.bool(forKey: "isAutoCropEnabled")
                let contrast = UserDefaults.standard.double(forKey: "comic_autoContrastLevel")
                let processed = await ReaderImageFilterEngine.shared.process(
                    url: url,
                    image: img,
                    isSmartCrop: isSmartCrop,
                    contrast: contrast,
                    saturation: 1.0,
                    warmth: 0.0
                )

                // Check cancellation BEFORE the await so the guard can actually fire.
                // Task.isCancelled inside MainActor.run is always false because the
                // cooperative check is not re-evaluated inside a synchronous block.
                guard !Task.isCancelled else { return }
                await MainActor.run { iv.image = processed }
            }
        }

        /// Tear-down: invalidate the display link and cancel all image loads.
        /// Called from dismantleUIView to break the CADisplayLink strong-reference cycle.
        func invalidate() {
            displayLink?.invalidate()
            displayLink = nil
            for task in loadTasks.values { task.cancel() }
            loadTasks.removeAll()
        }

        private func unloadImage(at index: Int) {
            guard index >= 0, index < imageViews.count else { return }
            loadTasks[index]?.cancel()
            loadTasks[index] = nil
            imageViews[index].image = nil
        }

        // MARK: - Scroll delegate

        func scrollViewDidScroll(_ sv: UIScrollView) {
            let midY = sv.contentOffset.y + sv.bounds.height / 2

            // Find which image view straddles the midpoint
            for iv in imageViews {
                guard let ph = iv.superview else { continue }
                let frame = ph.convert(ph.bounds, to: sv)
                if frame.contains(CGPoint(x: 0, y: midY)) {
                    let idx = iv.tag
                    if idx != parentView.currentPageIndex {
                        DispatchQueue.main.async { self.parentView.currentPageIndex = idx }
                    }
                    // Lazy-load neighbours
                    for offset in [-2, -1, 0, 1, 2] {
                        let ni = idx + offset
                        if ni >= 0 && ni < parentView.pages.count && loadTasks[ni] == nil {
                            loadImage(at: ni, url: parentView.pages[ni], into: imageViews[ni])
                        }
                    }
                    
                    // Sliding Window Eviction: Unload images outside [-4, +4] radius to prevent OOM memory leak
                    for key in loadTasks.keys {
                        if abs(key - idx) > 4 {
                            unloadImage(at: key)
                        }
                    }
                    
                    break
                }
            }

            // Persist offset (debounced by nature — only called during actual scroll)
            UserDefaults.standard.set(
                sv.contentOffset.y,
                forKey: parentView.savedOffsetKey
            )
            
            // End-of-strip detection: fire once when user scrolls to within 80pt of bottom
            let nearBottom = sv.contentOffset.y >= sv.contentSize.height - sv.bounds.height - 80
            if nearBottom && !hasReportedEnd && sv.contentSize.height > sv.bounds.height {
                hasReportedEnd = true
                DispatchQueue.main.async { self.parentView.onEndReached?() }
            } else if !nearBottom && hasReportedEnd {
                // Reset so it can fire again if user scrolls back up and then back down
                hasReportedEnd = false
            }
        }

        // MARK: - Auto-Scroll (CADisplayLink)

        func updateAutoScroll(isActive: Bool, speed: Double, sv: UIScrollView) {
            if isActive {
                if displayLink == nil {
                    let dl = CADisplayLink(target: self, selector: #selector(tick(_:)))
                    dl.add(to: .main, forMode: .common)
                    displayLink = dl
                }
            } else {
                displayLink?.invalidate()
                displayLink = nil
            }
        }

        @objc private func tick(_ dl: CADisplayLink) {
            guard let sv = scrollView else { return }
            let pxPerFrame = parentView.scrollSpeed * dl.duration
            let newY = min(sv.contentOffset.y + pxPerFrame,
                           sv.contentSize.height - sv.bounds.height)
            sv.contentOffset = CGPoint(x: 0, y: max(0, newY))
        }

        // MARK: - Tap

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let sv = scrollView else { return }
            let x = gr.location(in: sv).x
            let w = sv.bounds.width
            let zones = parentView.tapZoneStyle.zones
            if x < w * zones.leftEdge || x > w * zones.rightEdge {
                // Edge tap in webtoon: no page navigation (scroll handles position)
            } else {
                parentView.onCenterTap()
            }
        }

        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    // Expose tap zone to coordinator
    fileprivate var tapZoneStyle: TapZoneStyle {
        TapZoneStyle(rawValue: UserDefaults.standard.string(forKey: "tapZoneStyle") ?? "") ?? .classic
    }
}

// ============================================================================
// WebtoonControlBar — speed HUD overlay (shown when auto-scroll is active)
// ============================================================================
struct WebtoonControlBar: View {
    @Binding var isAutoScrolling: Bool
    @Binding var scrollSpeed: Double   // 20–200 px/sec

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if isAutoScrolling {
                HStack(spacing: 12) {
                    Button { scrollSpeed = max(20, scrollSpeed - 20) } label: {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Slider(value: $scrollSpeed, in: 20...200, step: 10)
                        .tint(Color.orange)
                        .frame(width: 120)

                    Button { scrollSpeed = min(200, scrollSpeed + 20) } label: {
                        Image(systemName: "hare.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text("\(Int(scrollSpeed)) px/s")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 110)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isAutoScrolling)
    }
}
