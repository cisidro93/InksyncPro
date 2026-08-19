import Foundation

// MARK: - Spaced Repetition SuperMemo-2 / FSRS Scheduler

/// Deterministic, zero-dependency Spaced Repetition engine implementing the SuperMemo-2 / FSRS baseline.
/// Conforms to Swift 6 Sendable and strict concurrency.
public struct StudyCardScheduler: Sendable {
    
    public static let shared = StudyCardScheduler()
    
    public init() {}
    
    // MARK: - Constants
    
    public static let minEaseFactor: Double = 1.3
    public static let maxEaseFactor: Double = 3.5
    public static let defaultEaseFactor: Double = 2.5
    
    // MARK: - Scheduling Calculation
    
    /// Schedules the next review date and updates repetition parameters based on user rating.
    /// - Parameters:
    ///   - card: The current `StudyCard` to update.
    ///   - rating: The user's assessment rating (`again`, `hard`, `good`, `easy`).
    ///   - currentDate: Reference date for scheduling (defaults to `Date()`).
    /// - Returns: A mutated copy of `StudyCard` with updated SRS parameters.
    public func scheduleNextReview(
        for card: StudyCard,
        rating: StudyReviewRating,
        currentDate: Date = Date()
    ) -> StudyCard {
        var updated = card
        let grade = rating.gradeScore // 1...4
        
        var newRepetition = card.repetitionCount
        var newEase = card.easeFactor
        var newInterval: Double
        
        switch rating {
        case .again:
            // Failed recall: reset repetitions and schedule immediate review in ~10 minutes
            newRepetition = 0
            newInterval = 0.007 // ~10 minutes in days (10 / 1440)
            newEase = max(Self.minEaseFactor, card.easeFactor - 0.20)
            
        case .hard:
            // Difficult recall: slight interval growth, decrease ease factor
            newRepetition += 1
            if card.repetitionCount == 0 {
                newInterval = 0.5 // 12 hours
            } else {
                newInterval = max(1.0, card.intervalDays * 1.2)
            }
            newEase = max(Self.minEaseFactor, card.easeFactor - 0.15)
            
        case .good:
            // Standard successful recall
            newRepetition += 1
            if newRepetition == 1 {
                newInterval = 1.0 // 1 day
            } else if newRepetition == 2 {
                newInterval = 6.0 // 6 days
            } else {
                newInterval = max(1.0, card.intervalDays * card.easeFactor)
            }
            
            // Standard SM-2 ease adjustment formula: EF' = EF + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))
            // where q = grade (good = 3, so 5 - 3 = 2)
            let qDiff = 5.0 - Double(grade)
            let deltaEase = 0.1 - (qDiff * (0.08 + (qDiff * 0.02)))
            newEase = max(Self.minEaseFactor, min(Self.maxEaseFactor, card.easeFactor + deltaEase))
            
        case .easy:
            // Rapid / effortless recall
            newRepetition += 1
            if newRepetition == 1 {
                newInterval = 4.0 // 4 days
            } else if newRepetition == 2 {
                newInterval = 10.0 // 10 days
            } else {
                newInterval = max(card.intervalDays * card.easeFactor * 1.3, 4.0)
            }
            newEase = min(Self.maxEaseFactor, card.easeFactor + 0.15)
        }
        
        // Calculate new due date from reference date
        let intervalSeconds = newInterval * 86400.0
        let newDueDate = currentDate.addingTimeInterval(intervalSeconds)
        
        updated.intervalDays = newInterval
        updated.repetitionCount = newRepetition
        updated.easeFactor = (newEase * 100).rounded() / 100 // Round to 2 decimal places
        updated.dueDate = newDueDate
        updated.modifiedAt = currentDate
        
        return updated
    }
    
    // MARK: - Preview Projections
    
    /// Computes projected interval days for each rating button option to display live in the UI.
    public func previewProjectedIntervals(for card: StudyCard) -> [StudyReviewRating: String] {
        var results: [StudyReviewRating: String] = [:]
        for rating in StudyReviewRating.allCases {
            let scheduled = scheduleNextReview(for: card, rating: rating)
            results[rating] = formatIntervalDescription(days: scheduled.intervalDays)
        }
        return results
    }
    
    // MARK: - Formatters
    
    /// Human-friendly compact interval string (e.g., "<10m", "12h", "1d", "6d", "3w", "2mo").
    public func formatIntervalDescription(days: Double) -> String {
        if days < 0.02 {
            return "<10m"
        } else if days < 1.0 {
            let hours = max(1, Int((days * 24).rounded()))
            return "\(hours)h"
        } else if days < 14.0 {
            let roundedDays = max(1, Int(days.rounded()))
            return "\(roundedDays)d"
        } else if days < 60.0 {
            let weeks = max(1, Int((days / 7.0).rounded()))
            return "\(weeks)w"
        } else if days < 365.0 {
            let months = max(1, Int((days / 30.4).rounded()))
            return "\(months)mo"
        } else {
            let years = String(format: "%.1f", days / 365.0)
            return "\(years)y"
        }
    }
}
