import Foundation

/// A persistent tracker to strictly enforce ComicVine's 200 requests/hour limit across app launches.
final class ComicVineRateTracker: Sendable {
    static let shared = ComicVineRateTracker()
    
    private let maxRequestsPerHour = 199
    private var defaults: UserDefaults { .standard }
    
    private let keyWindowStart = "comicVine_hourlyWindowStart"
    private let keyRequestCount = "comicVine_requestsThisHour"
    
    // Concurrent thread safety
    private let queue = DispatchQueue(label: "com.inksyncpro.ratetracker", attributes: .concurrent)
    
    private init() {
        validateWindow()
    }
    
    private func validateWindow() {
        if let windowStart = defaults.object(forKey: keyWindowStart) as? Date {
            let now = Date()
            if now.timeIntervalSince(windowStart) >= 3600 {
                // Window expired, reset counter
                defaults.set(now, forKey: keyWindowStart)
                defaults.set(0, forKey: keyRequestCount)
            }
        } else {
            // First time setup
            defaults.set(Date(), forKey: keyWindowStart)
            defaults.set(0, forKey: keyRequestCount)
        }
    }
    
    var requestsRemaining: Int {
        queue.sync {
            validateWindow()
            let currentCounts = defaults.integer(forKey: keyRequestCount)
            return max(maxRequestsPerHour - currentCounts, 0)
        }
    }
    
    var timeUntilReset: TimeInterval {
        queue.sync {
            validateWindow()
            guard let windowStart = defaults.object(forKey: keyWindowStart) as? Date else { return 0 }
            let elapsed = Date().timeIntervalSince(windowStart)
            return max(3600 - elapsed, 0)
        }
    }
    
    /// Checks if a request is permissible. If not, throws an error.
    func registerRequestAttempt() throws {
        try queue.sync(flags: .barrier) {
            validateWindow()
            let currentCounts = defaults.integer(forKey: keyRequestCount)
            
            if currentCounts >= maxRequestsPerHour {
                throw ComicVineError.rateLimited
            }
            
            defaults.set(currentCounts + 1, forKey: keyRequestCount)
        }
    }
}
