import Foundation
import SwiftUI

// MARK: - Reading Velocity Engine
//
// Computes reading velocity from the raw session events already captured by
// ReaderProgressTracker. No new data is collected — this is pure analytics
// on what's already there.
//
// Design principles:
//  • All computation is synchronous & off-MainActor safe (no @Published, no ObservableObject)
//  • Results are value types (structs) — safe to pass across actors
//  • The engine is stateless; call compute() from any context

struct VelocityReport: Sendable {
    // MARK: - Per-Book Velocity
    struct BookForecast: Identifiable, Sendable {
        let id: UUID            // ConvertedPDF.id
        let name: String
        let pagesRemaining: Int
        let pagesPerDay: Double          // rolling 14-day average for this book
        let globalPagesPerDay: Double    // user's overall daily pace (all books)
        let finishDate: Date?            // nil = not enough data
        let catchUpPagesPerDay: Int      // pages/day needed to finish by targetDate
        let targetDate: Date?            // user-set deadline, nil = none
        let isAheadOfPace: Bool
        let bestSessionPages: Int        // personal best in one session
        let averageSessionPages: Double
        let sessionCount: Int

        // Human-readable "finish by" string
        var finishByLabel: String {
            guard let date = finishDate else {
                return pagesRemaining == 0 ? "Finished ✓" : "Start reading to forecast"
            }
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            if days <= 0  { return "Almost done!" }
            if days == 1  { return "Finish tomorrow" }
            if days < 7   { return "Finish in \(days) days" }
            if days < 30  { return "Finish in \(days / 7) week\(days / 7 == 1 ? "" : "s")" }
            return "Finish in ~\(days / 30) month\(days / 30 == 1 ? "" : "s")"
        }

        var finishByShortLabel: String {
            guard let date = finishDate else { return "—" }
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            if days <= 0 { return "Soon" }
            if days == 1 { return "1 day" }
            if days < 7  { return "\(days)d" }
            if days < 30 { return "\(days / 7)w" }
            return "\(days / 30)mo"
        }

        var paceLabel: String {
            let ppm = globalPagesPerDay
            if ppm <= 0 { return "—" }
            return String(format: "%.0f pages/day", ppm)
        }
    }

    // MARK: - Library-wide Velocity
    struct GlobalStats: Sendable {
        let pagesPerDay: Double          // rolling 14-day across all books
        let pagesPerSession: Double      // rolling 10-session average
        let totalDaysOfReading: Int      // distinct days with any session
        let longestStreak: Int
        let fastestBook: String?         // name of book with highest velocity
        let slowestActiveBook: String?   // most-pages-remaining / lowest velocity
        let projectedLibraryFinishDays: Int? // days to finish all in-progress books
    }

    let books: [BookForecast]
    let global: GlobalStats
    let generatedAt: Date
}

// MARK: - Engine

enum ReadingVelocityEngine {

    // MARK: - Public API

    /// Compute velocity reports for all in-progress books.
    /// Safe to call from any actor — all work is pure computation on value-type copies.
    static func compute(
        pdfs: [ConvertedPDF],
        tracker: ReaderProgressTracker,
        targets: [UUID: Date] = [:]        // optional user-set deadlines per book
    ) async -> VelocityReport {
        // Collect all progress data up-front on MainActor
        let allProgress: [(pdf: ConvertedPDF, progress: ReadingProgress?)] = await MainActor.run {
            pdfs.map { ($0, tracker.progress(for: $0.id)) }
        }

        // Global stats from all session events
        let globalPPD = globalPagesPerDay(from: allProgress)
        let globalPPS = globalPagesPerSession(from: allProgress)
        let totalDays = totalDistinctReadingDays(from: allProgress)
        let streak    = longestHistoricStreak(from: allProgress)

        // Per-book forecasts — only for books with some progress
        var forecasts: [VelocityReport.BookForecast] = []
        for item in allProgress {
            guard let prog = item.progress, prog.completionFraction > 0, prog.completionFraction < 0.99 else { continue }
            let forecast = buildForecast(
                pdf: item.pdf,
                progress: prog,
                globalPPD: globalPPD,
                target: targets[item.pdf.id]
            )
            forecasts.append(forecast)
        }

        // Sort: soonest finish date first, then by most progress
        forecasts.sort {
            switch ($0.finishDate, $1.finishDate) {
            case let (a?, b?): return a < b
            case (nil, _):     return false
            case (_, nil):     return true
            }
        }

        // Global projected finish: sum all remaining days using global PPD
        let totalRemaining = forecasts.reduce(0) { $0 + $1.pagesRemaining }
        let projectedDays: Int? = globalPPD > 0 ? Int(ceil(Double(totalRemaining) / globalPPD)) : nil

        let fastestBook  = forecasts.max(by: { $0.pagesPerDay < $1.pagesPerDay })?.name
        let slowestBook  = forecasts.filter { $0.pagesPerDay > 0 }.min(by: { $0.pagesPerDay < $1.pagesPerDay })?.name

        let global = VelocityReport.GlobalStats(
            pagesPerDay: globalPPD,
            pagesPerSession: globalPPS,
            totalDaysOfReading: totalDays,
            longestStreak: streak,
            fastestBook: fastestBook,
            slowestActiveBook: slowestBook,
            projectedLibraryFinishDays: projectedDays
        )

        return VelocityReport(books: forecasts, global: global, generatedAt: Date())
    }

    // MARK: - Per-Book Forecast Builder

    private static func buildForecast(
        pdf: ConvertedPDF,
        progress: ReadingProgress,
        globalPPD: Double,
        target: Date?
    ) -> VelocityReport.BookForecast {
        let pagesRemaining = max(0, pdf.pageCount - progress.currentPageIndex - 1)

        // Book-specific velocity: rolling 14-day window of session events
        let bookPPD = bookPagesPerDay(from: progress, windowDays: 14)

        // Effective PPD: prefer book-specific if ≥ 3 sessions exist in window, else fall back to global
        let sessionCountInWindow = recentSessionCount(from: progress, windowDays: 14)
        let effectivePPD = sessionCountInWindow >= 3 ? bookPPD : (globalPPD > 0 ? globalPPD : bookPPD)

        // Finish date
        let finishDate: Date?
        if effectivePPD > 0 && pagesRemaining > 0 {
            let daysToFinish = Double(pagesRemaining) / effectivePPD
            finishDate = Calendar.current.date(byAdding: .day, value: Int(ceil(daysToFinish)), to: Date())
        } else if pagesRemaining == 0 {
            finishDate = Date()
        } else {
            finishDate = nil
        }

        // Catch-up pages/day to hit target
        let catchUpPPD: Int
        if let target = target, pagesRemaining > 0 {
            let daysToTarget = max(1, Calendar.current.dateComponents([.day], from: Date(), to: target).day ?? 1)
            catchUpPPD = Int(ceil(Double(pagesRemaining) / Double(daysToTarget)))
        } else {
            catchUpPPD = 0
        }

        let isAheadOfPace: Bool
        if let target, let finish = finishDate {
            isAheadOfPace = finish <= target
        } else {
            isAheadOfPace = true
        }

        // Session stats
        let events = progress.sessionEvents ?? []
        let best = events.map(\.pagesRead).max() ?? 0
        let avg  = events.isEmpty ? 0.0 : Double(events.map(\.pagesRead).reduce(0, +)) / Double(events.count)

        return VelocityReport.BookForecast(
            id: progress.pdfID,
            name: pdf.name,
            pagesRemaining: pagesRemaining,
            pagesPerDay: bookPPD,
            globalPagesPerDay: globalPPD,
            finishDate: finishDate,
            catchUpPagesPerDay: catchUpPPD,
            targetDate: target,
            isAheadOfPace: isAheadOfPace,
            bestSessionPages: best,
            averageSessionPages: avg,
            sessionCount: events.count
        )
    }

    // MARK: - Computation Helpers

    /// Pages per day for a single book over a rolling window.
    private static func bookPagesPerDay(from progress: ReadingProgress, windowDays: Int) -> Double {
        guard let events = progress.sessionEvents, !events.isEmpty else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86400)
        let recent = events.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return 0 }

        // Group by calendar day and sum pages per day
        let calendar = Calendar.current
        var byDay: [Date: Int] = [:]
        for event in recent {
            let day = calendar.startOfDay(for: event.date)
            byDay[day, default: 0] += event.pagesRead
        }
        let totalPages = byDay.values.reduce(0, +)
        let daysActive = max(1, byDay.count)
        return Double(totalPages) / Double(daysActive)
    }

    private static func recentSessionCount(from progress: ReadingProgress, windowDays: Int) -> Int {
        guard let events = progress.sessionEvents else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86400)
        return events.filter { $0.date >= cutoff }.count
    }

    /// Global pages per day: all books, rolling 14-day window.
    private static func globalPagesPerDay(from items: [(pdf: ConvertedPDF, progress: ReadingProgress?)]) -> Double {
        let calendar = Calendar.current
        var byDay: [Date: Int] = [:]
        let cutoff = Date().addingTimeInterval(-14 * 86400)

        for item in items {
            guard let events = item.progress?.sessionEvents else { continue }
            for event in events where event.date >= cutoff {
                let day = calendar.startOfDay(for: event.date)
                byDay[day, default: 0] += event.pagesRead
            }
        }
        guard !byDay.isEmpty else { return 0 }
        let totalPages = byDay.values.reduce(0, +)
        return Double(totalPages) / Double(max(1, byDay.count))
    }

    /// Average pages per session across all books (last 10 sessions).
    private static func globalPagesPerSession(from items: [(pdf: ConvertedPDF, progress: ReadingProgress?)]) -> Double {
        var allEvents: [ReadingSessionEvent] = []
        for item in items {
            allEvents.append(contentsOf: item.progress?.sessionEvents ?? [])
        }
        allEvents.sort { $0.date > $1.date }
        let recent = Array(allEvents.prefix(10))
        guard !recent.isEmpty else { return 0 }
        return Double(recent.map(\.pagesRead).reduce(0, +)) / Double(recent.count)
    }

    private static func totalDistinctReadingDays(from items: [(pdf: ConvertedPDF, progress: ReadingProgress?)]) -> Int {
        let calendar = Calendar.current
        var days = Set<Date>()
        for item in items {
            for event in item.progress?.sessionEvents ?? [] {
                days.insert(calendar.startOfDay(for: event.date))
            }
        }
        return days.count
    }

    private static func longestHistoricStreak(from items: [(pdf: ConvertedPDF, progress: ReadingProgress?)]) -> Int {
        let calendar = Calendar.current
        var days = Set<Date>()
        for item in items {
            for event in item.progress?.sessionEvents ?? [] {
                days.insert(calendar.startOfDay(for: event.date))
            }
            // Also count session dates (coarser fallback)
            for date in item.progress?.readingSessionDates ?? [] {
                days.insert(calendar.startOfDay(for: date))
            }
        }
        let sorted = days.sorted(by: >)
        var longest = 0
        var current = 0
        var prev: Date? = nil
        for day in sorted {
            if let p = prev,
               let expectedPrev = calendar.date(byAdding: .day, value: 1, to: day),
               calendar.isDate(expectedPrev, inSameDayAs: p) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            prev = day
        }
        return longest
    }
}

// MARK: - Convenience ViewModel wrapper

/// Lightweight @Observable wrapper so SwiftUI views can react to velocity updates.
@MainActor
final class VelocityViewModel: ObservableObject {
    @Published private(set) var report: VelocityReport? = nil
    @Published private(set) var isComputing = false

    /// Call this whenever the library or progress changes. Debounced internally.
    func refresh(pdfs: [ConvertedPDF], tracker: ReaderProgressTracker, targets: [UUID: Date] = [:]) {
        guard !isComputing else { return }
        isComputing = true
        Task {
            let result = await ReadingVelocityEngine.compute(pdfs: pdfs, tracker: tracker, targets: targets)
            self.report = result
            self.isComputing = false
        }
    }

    func forecast(for pdfID: UUID) -> VelocityReport.BookForecast? {
        report?.books.first { $0.id == pdfID }
    }
}
