import Foundation

// MARK: - ReviewStreakTracker
// Lightweight UserDefaults-backed singleton.
// Tracks the user's consecutive daily review streak independently of SwiftData.
// This is session metadata, not content — keeping it out of the model layer is intentional.

final class ReviewStreakTracker: Sendable {
    static let shared = ReviewStreakTracker()
    private init() {}

    private let streakKey      = "ink_review_streak_count"
    private let lastDateKey    = "ink_review_last_date"
    private let totalReviewKey = "ink_review_total_cards"

    // MARK: - Public API

    /// Current consecutive-day streak. Updates automatically when `recordSessionCompleted()` is called.
    var currentStreak: Int {
        UserDefaults.standard.integer(forKey: streakKey)
    }

    /// Total cards ever reviewed across all sessions.
    var totalCardsReviewed: Int {
        UserDefaults.standard.integer(forKey: totalReviewKey)
    }

    /// True if the user has already completed a review session today.
    var hasReviewedToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: lastDateKey) as? Date else { return false }
        return Calendar.current.isDateInToday(last)
    }

    /// Call once when the user finishes a review session.
    /// - Parameter cardCount: number of cards reviewed in this session.
    /// - Returns: the updated streak count.
    @discardableResult
    func recordSessionCompleted(cardCount: Int) -> Int {
        let defaults = UserDefaults.standard
        let now = Date()
        let calendar = Calendar.current

        // Increment total cards
        let previousTotal = defaults.integer(forKey: totalReviewKey)
        defaults.set(previousTotal + cardCount, forKey: totalReviewKey)

        // Already reviewed today — don't double-count streak
        if hasReviewedToday {
            return currentStreak
        }

        let previousStreak = defaults.integer(forKey: streakKey)
        let newStreak: Int

        if let lastDate = defaults.object(forKey: lastDateKey) as? Date {
            // If yesterday → extend streak; if older → reset to 1
            let daysSinceLast = calendar.dateComponents([.day], from: lastDate, to: now).day ?? 0
            newStreak = (daysSinceLast == 1) ? previousStreak + 1 : 1
        } else {
            // First ever session
            newStreak = 1
        }

        defaults.set(newStreak, forKey: streakKey)
        defaults.set(now, forKey: lastDateKey)
        return newStreak
    }

    /// Call if the user closes the session without rating any cards (streak should not advance).
    func cancelSession() {
        // No-op: we only record on completion.
    }

    /// Returns a human-readable description of when the next review is due.
    static func intervalDescription(days: Double) -> String {
        if days < 1 { return "today" }
        if days == 1 { return "tomorrow" }
        if days < 7 { return "in \(Int(days)) days" }
        let weeks = Int(days / 7)
        return "in \(weeks) \(weeks == 1 ? "week" : "weeks")"
    }
}
