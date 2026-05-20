import Foundation
import Combine
import SwiftUI

/// Tracks reading streaks and daily goal progress.
/// Isolated to `@MainActor` — all `@AppStorage` and `@Published` mutations
/// are guaranteed to occur on the main thread without `DispatchQueue.main.async`.
@MainActor
class GamificationManager: ObservableObject {
    static let shared = GamificationManager()

    @AppStorage("enableSerendipity") var enableSerendipity: Bool = true
    @AppStorage("streakCharges") var streakCharges: Int = 0
    @AppStorage("dailyPageGoal") var dailyPageGoal: Int = 5
    @AppStorage("currentStreak") var currentStreak: Int = 0
    @AppStorage("pagesReadToday") var pagesReadToday: Int = 0
    @AppStorage("lastReadingDate") private var lastReadingDateRaw: Double = 0

    var lastReadingDate: Date {
        get { Date(timeIntervalSince1970: lastReadingDateRaw) }
        set { lastReadingDateRaw = newValue.timeIntervalSince1970 }
    }

    private init() {
        checkStreakStatus()
    }

    /// Called when the app starts or comes to the foreground.
    func checkStreakStatus() {
        let calendar = Calendar.current
        let today = Date()

        if lastReadingDateRaw == 0 {
            lastReadingDate = today
            Logger.shared.log("GamificationManager: first launch, streak initialized", category: "Gamification", type: .info)
            return
        }

        if calendar.isDateInToday(lastReadingDate) {
            return
        }

        // It's a new day — reset the daily counter.
        pagesReadToday = 0
        Logger.shared.log("Gamification: new day detected, daily page counter reset", category: "Gamification", type: .info)

        if calendar.isDateInYesterday(lastReadingDate) {
            lastReadingDate = today
            return
        }

        // Missed at least one day — try to consume streak charges.
        let components = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastReadingDate), to: calendar.startOfDay(for: today))
        let missedDays = (components.day ?? 1) - 1

        if missedDays > 0 {
            if streakCharges >= missedDays {
                streakCharges -= missedDays
                Logger.shared.log("Gamification: \(missedDays) missed day(s) covered by streak charges (\(streakCharges) remaining)", category: "Gamification", type: .warning)
            } else {
                let lostStreak = currentStreak
                streakCharges = 0
                currentStreak = 0
                Logger.shared.log("Gamification: streak BROKEN after \(missedDays) missed day(s). Lost \(lostStreak)-day streak.", category: "Gamification", type: .warning)
            }
        }

        lastReadingDate = today
    }

    /// Call this from reader engines when a user turns a page.
    func logPageRead() {
        let calendar = Calendar.current
        if !calendar.isDateInToday(lastReadingDate) {
            checkStreakStatus()
        }

        let previouslyMetGoal = pagesReadToday >= dailyPageGoal
        pagesReadToday += 1
        let currentlyMetGoal = pagesReadToday >= dailyPageGoal

        if !previouslyMetGoal && currentlyMetGoal {
            currentStreak += 1
            streakCharges += 1
            Logger.shared.log("Gamification: daily goal met! streak=\(currentStreak) day(s), charges=\(streakCharges)", category: "Gamification", type: .success)
        }
    }
}

