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
    @State private var dismissTask: Task<Void, Never>? = nil

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
                            .foregroundStyle(Color.inkText)
                        
                        if let label = jump.chapterLabel, !label.isEmpty {
                            Text("Return to \(label) (p. \(jump.fromPage + 1))")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.inkSecondary)
                                .lineLimit(1)
                        } else {
                            Text("Tap to return to Page \(jump.fromPage + 1)")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }

                    Spacer()

                    Button {
                        HapticEngine.medium()
                        tracker.performUndo()
                    } label: {
                        Text("Return")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.inkViolet, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        HapticEngine.light()
                        tracker.dismissJump()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.inkSecondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.inkSurfaceRaised.opacity(0.95))
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .inkSpecularBorder(cornerRadius: 24)
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 5)
                .padding(.horizontal, 20)
                .padding(.bottom, 68)
            }
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            ))
            .zIndex(150)
            .onAppear {
                dismissTask?.cancel()
                dismissTask = Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds auto-dismiss
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        tracker.dismissJump()
                    }
                }
            }
            .onDisappear {
                dismissTask?.cancel()
            }
        }
    }
}
