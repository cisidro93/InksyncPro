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
