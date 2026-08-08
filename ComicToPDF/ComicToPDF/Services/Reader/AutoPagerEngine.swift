import SwiftUI
import Combine

@MainActor
public final class AutoPagerEngine: ObservableObject {
    public static let shared = AutoPagerEngine()
    private init() {}

    @Published public var isActive = false
    @Published public var intervalSeconds: Double = 30.0
    @Published public var timeRemainingSeconds: Double = 30.0

    private var timerSubscription: AnyCancellable? = nil
    private var advanceAction: (@MainActor () -> Void)? = nil

    public func start(intervalSeconds: Double = 30.0, advanceAction: @escaping @MainActor () -> Void) {
        self.intervalSeconds = intervalSeconds
        self.timeRemainingSeconds = intervalSeconds
        self.advanceAction = advanceAction
        self.isActive = true

        timerSubscription?.cancel()
        timerSubscription = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isActive else { return }
                if self.timeRemainingSeconds <= 1.0 {
                    self.timeRemainingSeconds = self.intervalSeconds
                    self.advanceAction?()
                    HapticEngine.light()
                } else {
                    self.timeRemainingSeconds -= 1.0
                }
            }
    }

    public func stop() {
        self.isActive = false
        timerSubscription?.cancel()
        timerSubscription = nil
        self.advanceAction = nil
    }

    public func toggle(intervalSeconds: Double = 30.0, advanceAction: @escaping @MainActor () -> Void) {
        if isActive {
            stop()
        } else {
            start(intervalSeconds: intervalSeconds, advanceAction: advanceAction)
        }
    }
}
