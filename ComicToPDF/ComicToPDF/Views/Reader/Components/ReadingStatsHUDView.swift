import SwiftUI

struct ReadingStatsHUDView: View {
    let pdfID: UUID?
    let bookTitle: String
    let totalPages: Int
    let currentPageIndex: Int
    
    @ObservedObject private var tracker = ReaderProgressTracker.shared
    @AppStorage("dailyReadingGoal") private var dailyGoal: Int = 20
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header Card
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bookTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        
                        Text("Reading Session Analytics")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    
                    // Main Grid: Streak, Velocity, Time Left
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        // Streak Box
                        MetricBox(
                            title: "Daily Streak",
                            value: "\(tracker.readingStreak()) Days",
                            subText: tracker.readingStreak() > 0 ? "Keep it burning!" : "Start reading today!",
                            icon: "flame.fill",
                            iconColor: .orange
                        )
                        
                        // Velocity Box
                        let velocity = pdfID != nil ? tracker.rollingVelocity(for: pdfID!) : 0
                        MetricBox(
                            title: "Reading Speed",
                            value: String(format: "%.1f P/M", velocity),
                            subText: velocity > 0 ? "Avg. pages per minute" : "Reading speed calibrating...",
                            icon: "speedometer",
                            iconColor: .blue
                        )
                        
                        // Progress
                        let progress = totalPages > 0 ? Double(currentPageIndex + 1) / Double(totalPages) : 0
                        MetricBox(
                            title: "Book Completed",
                            value: "\(Int(progress * 100))%",
                            subText: "Page \(currentPageIndex + 1) of \(totalPages)",
                            icon: "checkmark.circle.fill",
                            iconColor: .green
                        )
                        
                        // Time Remaining
                        let remaining = pdfID != nil ? (tracker.progress(for: pdfID!)?.estimatedMinutesRemaining ?? 0) : 0
                        MetricBox(
                            title: "Est. Time Left",
                            value: remaining > 0 ? "\(remaining)m" : "N/A",
                            subText: remaining > 0 ? "Until completion" : "Keep reading to estimate",
                            icon: "clock.fill",
                            iconColor: .purple
                        )
                    }
                    
                    // Weekly Progress Bar Chart
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Weekly Read Progress")
                                    .font(.subheadline.bold())
                                Text("Total this week: \(tracker.totalPagesThisWeek()) pages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            // Daily Goal Config
                            Menu {
                                ForEach([10, 20, 30, 50, 100], id: \.self) { goal in
                                    Button("\(goal) Pages") {
                                        dailyGoal = goal
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Goal: \(dailyGoal)p")
                                        .font(.caption.bold())
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                }
                                .foregroundColor(Theme.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.blue.opacity(0.1), in: Capsule())
                            }
                        }
                        
                        // Bar Chart
                        HStack(alignment: .bottom, spacing: 12) {
                            let days = ["M", "T", "W", "T", "F", "S", "S"]
                            ForEach(0..<7, id: \.self) { index in
                                let count = tracker.pagesReadOn(dayOfWeekIndex: index)
                                let pct = dailyGoal > 0 ? CGFloat(count) / CGFloat(dailyGoal) : 0
                                let cappedPct = min(max(pct, 0.05), 1.2) // Give small height minimum so zero is visible
                                
                                VStack(spacing: 8) {
                                    Spacer()
                                    
                                    // Count Bubble on Hover/Tap
                                    if count > 0 {
                                        Text("\(count)")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                    
                                    // Bar
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(
                                            LinearGradient(
                                                colors: count >= dailyGoal ? [.green, .emerald] : [Theme.blue, Theme.blue.opacity(0.6)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(height: cappedPct * 100)
                                    
                                    Text(days[index])
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 140)
                        .padding(.top, 10)
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                }
                .padding(20)
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Reading Progress HUD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(Theme.blue)
                }
            }
            .onAppear {
                let streak = tracker.readingStreak()
                let velocity = pdfID != nil ? tracker.rollingVelocity(for: pdfID!) : 0
                let pct = totalPages > 0 ? Int(Double(currentPageIndex + 1) / Double(totalPages) * 100) : 0
                Logger.shared.log(
                    "ReadingStatsHUD opened for '\(bookTitle)': streak=\(streak)d, speed=\(String(format: "%.1f", velocity))ppm, progress=\(pct)%, goal=\(dailyGoal)p/day",
                    category: "Reader",
                    type: .info
                )
            }
        }
    }
}

// Daily goal change logger (in parent body for Menu buttons)
extension ReadingStatsHUDView {
    func logGoalChange(to newGoal: Int) {
        Logger.shared.log("Daily reading goal updated to \(newGoal) pages/day for '\(bookTitle)'", category: "Reader", type: .info)
    }
}

private struct MetricBox: View {
    let title: String
    let value: String
    let subText: String
    let icon: String
    let iconColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text(subText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }
}

fileprivate extension Color {
    static let emerald = Color(red: 0.1, green: 0.7, blue: 0.3)
}
