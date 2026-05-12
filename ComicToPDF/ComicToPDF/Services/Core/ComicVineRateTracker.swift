import Foundation

// Actor-isolated ComicVine API rate limiter.
// ComicVine API limit: 200 requests/hour per key.
// We use 190/hour as the safe upper bound.

actor ComicVineRateTracker {
    static let shared = ComicVineRateTracker()

    private let maxPerHour: Int = 190
    private var windowStart: Date = Date()
    private var requestCount: Int = 0

    private init() {}

    // Returns the number of seconds until the next slot is available.
    // If 0, the caller may proceed immediately.
    func secondsUntilNextSlot() -> TimeInterval {
        let elapsed = Date().timeIntervalSince(windowStart)

        if elapsed >= 3600 {
            // Window has expired — reset
            windowStart = Date()
            requestCount = 0
            return 0
        }

        if requestCount < maxPerHour {
            return 0
        }

        // We've hit the limit — return remaining window time
        return 3600 - elapsed
    }

    // Call this to consume a slot. Returns the wait duration (0 = proceed immediately).
    func consume() -> TimeInterval {
        let wait = secondsUntilNextSlot()
        if wait == 0 {
            requestCount += 1
        }
        return wait
    }

    func requestCount_snapshot() -> Int { requestCount }
    func windowStart_snapshot() -> Date { windowStart }
}
