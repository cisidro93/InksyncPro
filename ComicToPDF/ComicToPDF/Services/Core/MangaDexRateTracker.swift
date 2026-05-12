import Foundation

// Actor-isolated MangaDex API rate limiter.
// MangaDex limit: 60 requests per 5-minute rolling window.
// We use 58 as the safe upper bound.

actor MangaDexRateTracker {
    static let shared = MangaDexRateTracker()

    private let maxPer5Minutes: Int = 58
    private let windowDuration: TimeInterval = 300
    private var windowStart: Date = Date()
    private var requestCount: Int = 0

    private init() {}

    func secondsUntilNextSlot() -> TimeInterval {
        let elapsed = Date().timeIntervalSince(windowStart)

        if elapsed >= windowDuration {
            windowStart = Date()
            requestCount = 0
            return 0
        }

        if requestCount < maxPer5Minutes {
            return 0
        }

        return windowDuration - elapsed
    }

    func consume() -> TimeInterval {
        let wait = secondsUntilNextSlot()
        if wait == 0 {
            requestCount += 1
        }
        return wait
    }
}
