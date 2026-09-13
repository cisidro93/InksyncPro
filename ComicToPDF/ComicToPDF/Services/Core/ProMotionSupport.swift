import SwiftUI
import QuartzCore

/// ProMotion support modifier.
///
/// Native 120Hz ProMotion responsiveness for gestures, scrolling, PencilKit inking,
/// and animations is natively unlocked via `CADisableMinimumFrameDurationOnPhone` in Info.plist.
/// We intentionally avoid running a continuous background `CADisplayLink` with `minimum: 80`
/// because doing so prevents Apple Silicon GPUs from downclocking the display to 10Hz/24Hz
/// when viewing static content, which leads to severe thermal heating and rapid battery drain.
public struct ProMotionFrameRateModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
    }
}

extension View {
    /// Enables adaptive 120Hz ProMotion interaction while allowing Apple Silicon to downclock to 10Hz/24Hz when idle.
    public func forceProMotion() -> some View {
        self.modifier(ProMotionFrameRateModifier())
    }
}
