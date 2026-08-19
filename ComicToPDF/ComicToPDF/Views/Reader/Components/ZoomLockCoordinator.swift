import SwiftUI

// MARK: - Zoom Lock Coordinator

/// Coordinates persistent zoom level, anchor point, and pan offset across consecutive comic/manga page turns.
/// When engaged, navigating to subsequent pages preserves the exact viewport crop rather than snapping back to fit-to-screen.
@MainActor
final class ZoomLockCoordinator: ObservableObject {
    
    static let shared = ZoomLockCoordinator()
    
    @Published var isZoomLocked: Bool = false
    @Published private(set) var lockedScale: CGFloat = 1.0
    @Published private(set) var lockedOffset: CGSize = .zero
    @Published private(set) var lockedAnchor: UnitPoint = .center
    
    init() {}
    
    // MARK: - API
    
    /// Records active viewport zoom scale and pan offset to persist across page turns.
    func lockCurrentViewport(scale: CGFloat, offset: CGSize, anchor: UnitPoint = .center) {
        guard scale > 1.05 else { return }
        self.lockedScale = scale
        self.lockedOffset = offset
        self.lockedAnchor = anchor
        self.isZoomLocked = true
        HapticEngine.success()
    }
    
    /// Releases the persistent zoom lock, reverting page turns to fit-to-screen.
    func unlock() {
        self.isZoomLocked = false
        self.lockedScale = 1.0
        self.lockedOffset = .zero
        self.lockedAnchor = .center
        HapticEngine.light()
    }
    
    /// Toggles the zoom lock state with current parameters.
    func toggleLock(currentScale: CGFloat, currentOffset: CGSize) {
        if isZoomLocked {
            unlock()
        } else {
            lockCurrentViewport(scale: currentScale, offset: currentOffset)
        }
    }
}

// MARK: - Zoom Lock HUD Button

/// Glassmorphic HUD button allowing readers to toggle persistent viewport zoom lock.
struct ZoomLockButton: View {
    @ObservedObject var coordinator: ZoomLockCoordinator
    let currentScale: CGFloat
    let currentOffset: CGSize
    
    init(
        coordinator: ZoomLockCoordinator = .shared,
        currentScale: CGFloat,
        currentOffset: CGSize
    ) {
        self.coordinator = coordinator
        self.currentScale = currentScale
        self.currentOffset = currentOffset
    }
    
    var body: some View {
        Button {
            coordinator.toggleLock(currentScale: currentScale, currentOffset: currentOffset)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: coordinator.isZoomLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12, weight: .bold))
                Text(coordinator.isZoomLocked ? "Zoom Locked (\(Int(round(coordinator.lockedScale * 100)))%)" : "Lock Zoom")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(coordinator.isZoomLocked ? .inkAmber : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if coordinator.isZoomLocked {
                    Color.inkAmber.opacity(0.18)
                } else {
                    Color.inkSurface.opacity(0.85).background(.ultraThinMaterial)
                }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(coordinator.isZoomLocked ? Color.inkAmber.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
