import SwiftUI
import QuartzCore

public struct ProMotionFrameRateModifier: ViewModifier {
    @State private var displayLink: CADisplayLink?

    public init() {}

    public func body(content: Content) -> some View {
        content
            .onAppear {
                let link = CADisplayLink(target: FrameRateTracker(), selector: #selector(FrameRateTracker.dummy))
                if #available(iOS 15.0, *) {
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                }
                link.add(to: .main, forMode: .common)
                self.displayLink = link
                
                // Automatically pause after 1.5 seconds to protect battery life and prevent device heating
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.displayLink?.isPaused = true
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
