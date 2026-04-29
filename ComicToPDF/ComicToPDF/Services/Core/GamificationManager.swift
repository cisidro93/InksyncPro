import Foundation
import Combine
import SwiftUI

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
    
    /// Called when the app starts or comes to the foreground
    func checkStreakStatus() {
        let calendar = Calendar.current
        let today = Date()
        
        if lastReadingDateRaw == 0 {
            // First time ever
            lastReadingDate = today
            return
        }
        
        if calendar.isDateInToday(lastReadingDate) {
            // Already read today, do nothing
            return
        }
        
        // It's a new day! Reset pages read today.
        pagesReadToday = 0
        
        if calendar.isDateInYesterday(lastReadingDate) {
            // Safe, they read yesterday. Just update the last check date.
            lastReadingDate = today
            return
        }
        
        // They missed at least one day.
        let components = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastReadingDate), to: calendar.startOfDay(for: today))
        let missedDays = (components.day ?? 1) - 1
        
        if missedDays > 0 {
            // Try to consume streak charges
            if streakCharges >= missedDays {
                streakCharges -= missedDays
                // Streak survives!
            } else {
                // Not enough charges, the streak breaks.
                streakCharges = 0
                currentStreak = 0
            }
        }
        
        lastReadingDate = today
    }
    
    /// Call this from the Reader engines when a user turns a page
    func logPageRead() {
        DispatchQueue.main.async {
            let calendar = Calendar.current
            if !calendar.isDateInToday(self.lastReadingDate) {
                self.checkStreakStatus()
            }
            
            let previouslyMetGoal = self.pagesReadToday >= self.dailyPageGoal
            
            self.pagesReadToday += 1
            
            let currentlyMetGoal = self.pagesReadToday >= self.dailyPageGoal
            
            if !previouslyMetGoal && currentlyMetGoal {
                // Reached the goal for today!
                self.currentStreak += 1
                self.streakCharges += 1 // Grant a streak charge
            }
        }
    }
}
