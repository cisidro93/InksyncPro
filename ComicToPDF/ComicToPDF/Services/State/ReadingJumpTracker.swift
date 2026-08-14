import SwiftUI

@MainActor
public final class ReadingJumpTracker: ObservableObject {
    public static let shared = ReadingJumpTracker()
    private init() {}

    public struct JumpTarget: Identifiable, Sendable {
        public let id = UUID()
        public let fromPage: Int
        public let toPage: Int
        public let chapterLabel: String?
        public let undoAction: @MainActor () -> Void

        public init(fromPage: Int, toPage: Int, chapterLabel: String? = nil, undoAction: @escaping @MainActor () -> Void) {
            self.fromPage = fromPage
            self.toPage = toPage
            self.chapterLabel = chapterLabel
            self.undoAction = undoAction
        }
    }

    @Published public var activeJump: JumpTarget? = nil

    public func recordJump(fromPage: Int, toPage: Int, chapterLabel: String? = nil, undoAction: @escaping @MainActor () -> Void) {
        guard fromPage != toPage else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            self.activeJump = JumpTarget(fromPage: fromPage, toPage: toPage, chapterLabel: chapterLabel, undoAction: undoAction)
        }
    }

    public func performUndo() {
        guard let jump = activeJump else { return }
        jump.undoAction()
        dismissJump()
    }

    public func dismissJump() {
        withAnimation(.easeInOut(duration: 0.2)) {
            self.activeJump = nil
        }
    }
}

public struct ReadingJumpToastOverlay: View {
    @ObservedObject private var tracker = ReadingJumpTracker.shared

    public init() {}

    public var body: some View {
        if let jump = tracker.activeJump {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jumped to Page \(jump.toPage + 1)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Tap to return to Page \(jump.fromPage + 1)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Spacer()

                    Button {
                        HapticEngine.medium()
                        tracker.performUndo()
                    } label: {
                        Text("Return")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white, in: Capsule())
                    }

                    Button {
                        tracker.dismissJump()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.85))
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 64)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(150)
        }
    }
}
