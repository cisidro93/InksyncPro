import SwiftUI
import QuartzCore

public struct ProMotionFrameRateModifier: ViewModifier {
    @State private var displayLink: CADisplayLink?

    public init() {}

    public func body(content: Content) -> some View {
        content
            .onAppear {
                // Invalidate existing display link if onAppear is called repeatedly to prevent memory leaks
                displayLink?.invalidate()
                
                let link = CADisplayLink(target: FrameRateTracker(), selector: #selector(FrameRateTracker.dummy))
                if #available(iOS 15.0, *) {
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                }
                link.add(to: .main, forMode: .common)
                self.displayLink = link
                
                // Automatically pause after 1.5 seconds to protect battery life and prevent device heating.
                // Capture link weakly so it is not retained if the view disappears before the timeout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak link] in
                    link?.isPaused = true
                }
            }
            .onDisappear {
                displayLink?.invalidate()
                displayLink = nil
            }
    }

    private class FrameRateTracker: NSObject {
        @objc func dummy() {}
    }
}

extension View {
    public func forceProMotion() -> some View {
        self.modifier(ProMotionFrameRateModifier())
    }
}
