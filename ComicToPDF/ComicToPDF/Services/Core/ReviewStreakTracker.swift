import Foundation

// MARK: - ReviewActivityTracker
// Lightweight UserDefaults-backed singleton.
// Tracks the user's review activity and card retention statistics purely for learning insights.
// Free of streak fatigue and gamification — reading and reviewing should be a joyful sanctuary,
// never a late-night chore driven by fear of breaking a consecutive-day counter.

final class ReviewActivityTracker: Sendable {
    static let shared = ReviewActivityTracker()
    private init() {}

    private let totalReviewKey = "ink_review_total_cards"
    private let historyKey     = "ink_review_history_volume"
    private let lastDateKey    = "ink_review_last_date"

    // MARK: - Public API

    /// Total cards ever reviewed across all sessions.
    var totalCardsReviewed: Int {
        UserDefaults.standard.integer(forKey: totalReviewKey)
    }

    /// Retrieve the history of daily review volumes (for the Mind Palace ink droplets visualization).
    var reviewHistory: [String: Int] {
        UserDefaults.standard.dictionary(forKey: historyKey) as? [String: Int] ?? [:]
    }

    /// True if the user has completed a review session today.
    var hasReviewedToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: lastDateKey) as? Date else { return false }
        return Calendar.current.isDateInToday(last)
    }

    /// Call once when the user finishes a review session.
    /// - Parameter cardCount: number of cards reviewed in this session.
    /// - Returns: updated total cards reviewed.
    @discardableResult
    func recordSessionCompleted(cardCount: Int) -> Int {
        let defaults = UserDefaults.standard
        let now = Date()

        // Increment total cards
        let previousTotal = defaults.integer(forKey: totalReviewKey)
        let newTotal = previousTotal + cardCount
        defaults.set(newTotal, forKey: totalReviewKey)

        // Record history log for visual heatmap
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateString = df.string(from: now)
        var history = defaults.dictionary(forKey: historyKey) as? [String: Int] ?? [:]
        history[dateString, default: 0] += cardCount
        defaults.set(history, forKey: historyKey)
        defaults.set(now, forKey: lastDateKey)

        return newTotal
    }

    /// Call if the user closes the session without rating any cards.
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

/// Backwards compatibility alias ensuring zero call-site breakage.
typealias ReviewStreakTracker = ReviewActivityTracker
