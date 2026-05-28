import Foundation
import Combine
import SwiftUI

// MARK: - Achievement Definition

struct ReadingAchievement: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let description: String
    let icon: String             // SF Symbol name
    let category: Category
    var unlockedAt: Date? = nil
    var isUnlocked: Bool { unlockedAt != nil }

    enum Category: String, Codable {
        case streak, velocity, volume, narration, collection
    }
}

// MARK: - GamificationManager

/// Tracks reading streaks, daily goal progress, velocity achievements, and narration milestones.
/// Isolated to `@MainActor` — all `@AppStorage` and `@Published` mutations
/// are guaranteed to occur on the main thread without `DispatchQueue.main.async`.
@MainActor
class GamificationManager: ObservableObject {
    static let shared = GamificationManager()

    // MARK: - Streak & Daily Goal

    @AppStorage("enableSerendipity") var enableSerendipity: Bool = true
    @AppStorage("streakCharges") var streakCharges: Int = 0
    @AppStorage("dailyPageGoal") var dailyPageGoal: Int = 5
    @AppStorage("currentStreak") var currentStreak: Int = 0
    @AppStorage("pagesReadToday") var pagesReadToday: Int = 0
    @AppStorage("lastReadingDate") private var lastReadingDateRaw: Double = 0
    @AppStorage("totalPagesEverRead") var totalPagesEverRead: Int = 0

    // MARK: - Session Velocity Tracking

    /// Pages read in the current active reading session (reset on session end or app background).
    @Published private(set) var sessionPageCount: Int = 0
    private var sessionStartTime: Date = Date()
    private var sessionTimer: Task<Void, Never>? = nil
    private let sessionIdleTimeout: TimeInterval = 5 * 60   // 5 min idle = session end

    // MARK: - Achievements

    @Published private(set) var achievements: [ReadingAchievement] = GamificationManager.allAchievements
    @Published private(set) var newlyUnlocked: ReadingAchievement? = nil   // shown in HUD toast

    // MARK: - Achievement Definitions (one-time purchase, no IAP gates)

    static let allAchievements: [ReadingAchievement] = [
        // Streak achievements
        ReadingAchievement(id: "streak_3",   title: "On a Roll",      description: "3-day reading streak",    icon: "flame",              category: .streak),
        ReadingAchievement(id: "streak_7",   title: "Week Warrior",   description: "7-day reading streak",    icon: "flame.fill",         category: .streak),
        ReadingAchievement(id: "streak_30",  title: "Iron Reader",    description: "30-day reading streak",   icon: "shield.fill",        category: .streak),
        ReadingAchievement(id: "streak_100", title: "Centurion",      description: "100-day reading streak",  icon: "crown.fill",         category: .streak),

        // Volume achievements
        ReadingAchievement(id: "pages_100",  title: "First Hundred",  description: "Read 100 pages",          icon: "book.fill",          category: .volume),
        ReadingAchievement(id: "pages_500",  title: "Half a Thousand",description: "Read 500 pages",          icon: "books.vertical.fill",category: .volume),
        ReadingAchievement(id: "pages_1000", title: "Grand Reader",   description: "Read 1,000 pages",        icon: "star.fill",          category: .volume),
        ReadingAchievement(id: "pages_5000", title: "Library Lord",   description: "Read 5,000 pages",        icon: "trophy.fill",        category: .volume),

        // Velocity achievements
        ReadingAchievement(id: "velocity_25_session",  title: "Speed Reader",   description: "25 pages in one session",  icon: "bolt.fill",          category: .velocity),
        ReadingAchievement(id: "velocity_50_session",  title: "Binge Mode",     description: "50 pages in one session",  icon: "bolt.horizontal.fill",category: .velocity),
        ReadingAchievement(id: "velocity_100_session", title: "Hyperdrive",     description: "100 pages in one session", icon: "flame.circle.fill",  category: .velocity),
        ReadingAchievement(id: "velocity_daily_2x",    title: "Overachiever",   description: "Read 2× daily goal in one day", icon: "2.circle.fill", category: .velocity),
        ReadingAchievement(id: "velocity_daily_3x",    title: "Legend",         description: "Read 3× daily goal in one day", icon: "3.circle.fill", category: .velocity),

        // Narration achievements
        ReadingAchievement(id: "narration_first",      title: "Listen Up",      description: "Used narration mode",      icon: "headphones",         category: .narration),
        ReadingAchievement(id: "narration_5books",     title: "Audiobook Fan",  description: "Narrated 5 full comics",   icon: "waveform.circle.fill",category: .narration),
    ]

    var lastReadingDate: Date {
        get { Date(timeIntervalSince1970: lastReadingDateRaw) }
        set { lastReadingDateRaw = newValue.timeIntervalSince1970 }
    }

    private init() {
        loadAchievements()
        checkStreakStatus()
    }

    // MARK: - Streak Logic

    /// Called when the app starts or comes to the foreground.
    func checkStreakStatus() {
        let calendar = Calendar.current
        let today = Date()

        if lastReadingDateRaw == 0 {
            lastReadingDate = today
            Logger.shared.log("GamificationManager: first launch, streak initialized", category: "Gamification", type: .info)
            return
        }

        if calendar.isDateInToday(lastReadingDate) { return }

        pagesReadToday = 0
        Logger.shared.log("Gamification: new day detected, daily page counter reset", category: "Gamification", type: .info)

        if calendar.isDateInYesterday(lastReadingDate) {
            lastReadingDate = today
            return
        }

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

    // MARK: - Page Read Logging (called by all reader engines)

    /// Call this from reader engines when a user turns a page.
    func logPageRead() {
        let calendar = Calendar.current
        if !calendar.isDateInToday(lastReadingDate) {
            checkStreakStatus()
        }

        let previouslyMetGoal = pagesReadToday >= dailyPageGoal
        pagesReadToday += 1
        totalPagesEverRead += 1
        sessionPageCount += 1

        // Reset idle timer
        resetSessionTimer()

        // Goal met for the first time today → advance streak
        let currentlyMetGoal = pagesReadToday >= dailyPageGoal
        if !previouslyMetGoal && currentlyMetGoal {
            currentStreak += 1
            streakCharges += 1
            Logger.shared.log("Gamification: daily goal met! streak=\(currentStreak) day(s), charges=\(streakCharges)", category: "Gamification", type: .success)
        }

        // Check all achievements after each page
        checkAchievements()
    }

    // MARK: - Narration Logging

    func logNarrationUsed() {
        unlock(id: "narration_first")
    }

    func logNarrationBookCompleted() {
        // Increment narrated book count
        let key = "narratedBooksCount"
        let count = (UserDefaults.standard.integer(forKey: key)) + 1
        UserDefaults.standard.set(count, forKey: key)
        if count >= 5 { unlock(id: "narration_5books") }
    }

    // MARK: - Velocity Integration
    //
    // VelocityEngine reports are surfaced here to gate velocity achievements.
    // This is the hook point for "Speed Reader: 50 pages in one session" etc.
    // Called by VelocityViewModel after each report refresh.

    func updateVelocityMetrics(report: VelocityReport?) {
        guard let report else { return }
        let globalPPD = report.global.pagesPerDay
        // If global pace is >= 2× daily goal, acknowledge it
        if globalPPD >= Double(dailyPageGoal * 2) {
            Logger.shared.log("Gamification: velocity 2× goal detected (\(Int(globalPPD)) p/day)", category: "Gamification")
        }
    }

    // MARK: - Achievement Check

    private func checkAchievements() {
        // Streak
        if currentStreak >= 3   { unlock(id: "streak_3") }
        if currentStreak >= 7   { unlock(id: "streak_7") }
        if currentStreak >= 30  { unlock(id: "streak_30") }
        if currentStreak >= 100 { unlock(id: "streak_100") }

        // Volume (total ever read)
        if totalPagesEverRead >= 100  { unlock(id: "pages_100") }
        if totalPagesEverRead >= 500  { unlock(id: "pages_500") }
        if totalPagesEverRead >= 1000 { unlock(id: "pages_1000") }
        if totalPagesEverRead >= 5000 { unlock(id: "pages_5000") }

        // Velocity — per-session
        if sessionPageCount >= 25  { unlock(id: "velocity_25_session") }
        if sessionPageCount >= 50  { unlock(id: "velocity_50_session") }
        if sessionPageCount >= 100 { unlock(id: "velocity_100_session") }

        // Velocity — daily multiplier
        if pagesReadToday >= dailyPageGoal * 2 { unlock(id: "velocity_daily_2x") }
        if pagesReadToday >= dailyPageGoal * 3 { unlock(id: "velocity_daily_3x") }
    }

    // MARK: - Unlock

    private func unlock(id: String) {
        guard let idx = achievements.firstIndex(where: { $0.id == id }),
              !achievements[idx].isUnlocked else { return }
        achievements[idx].unlockedAt = Date()
        newlyUnlocked = achievements[idx]
        saveAchievements()
        Logger.shared.log("🏆 Achievement unlocked: \(achievements[idx].title)", category: "Gamification", type: .success)
        HapticEngine.success()

        // Auto-clear the toast after 3 seconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run { [weak self] in
                self?.newlyUnlocked = nil
            }
        }
    }

    // MARK: - Session Management

    private func resetSessionTimer() {
        sessionTimer?.cancel()
        sessionTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.sessionIdleTimeout ?? 300) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                Logger.shared.log("Gamification: session ended after idle (\(self?.sessionPageCount ?? 0) pages)", category: "Gamification")
                self?.sessionPageCount = 0
                self?.sessionStartTime = Date()
            }
        }
    }

    // MARK: - Persistence

    private func saveAchievements() {
        if let data = try? JSONEncoder().encode(achievements) {
            UserDefaults.standard.set(data, forKey: "unlocked_achievements")
        }
    }

    private func loadAchievements() {
        guard let data = UserDefaults.standard.data(forKey: "unlocked_achievements"),
              let saved = try? JSONDecoder().decode([ReadingAchievement].self, from: data) else { return }
        // Merge: keep the full static list but restore unlocked dates from storage
        var merged = GamificationManager.allAchievements
        for i in merged.indices {
            if let saved = saved.first(where: { $0.id == merged[i].id }) {
                merged[i].unlockedAt = saved.unlockedAt
            }
        }
        achievements = merged
    }
}

// MARK: - Achievement Toast View

struct AchievementToastView: View {
    let achievement: ReadingAchievement

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(categoryGradient)
                    .frame(width: 44, height: 44)
                Image(systemName: achievement.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Achievement Unlocked!")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                Text(achievement.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text(achievement.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(categoryColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: categoryColor.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    private var categoryColor: Color {
        switch achievement.category {
        case .streak:    return .orange
        case .velocity:  return Color(hex: "#7C3AED")
        case .volume:    return Color(hex: "#0EA5E9")
        case .narration: return .green
        case .collection: return Color(hex: "#F59E0B")
        }
    }

    private var categoryGradient: LinearGradient {
        LinearGradient(
            colors: [categoryColor, categoryColor.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
