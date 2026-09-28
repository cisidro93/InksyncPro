import SwiftUI

struct ReadingStatsHUDView: View {
    let pdfID: UUID?
    let bookTitle: String
    let totalPages: Int
    let currentPageIndex: Int
    
    @ObservedObject private var tracker = ReaderProgressTracker.shared
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
                    
                    // Main Grid: Mindful Metrics (Time Read, Velocity, Progress, Time Left)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        // Mindful Reading Time Box
                        let minutes = tracker.totalMinutesReadToday()
                        MetricBox(
                            title: "Time Read Today",
                            value: minutes > 0 ? "\(minutes)m" : "0m",
                            subText: minutes > 0 ? "Mindful reading enjoyed" : "Read at your own pace",
                            icon: "clock.fill",
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
                    
                    // Weekly Activity Bar Chart
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Weekly Reading Activity")
                                    .font(.subheadline.bold())
                                Text("Total this week: \(tracker.totalPagesThisWeek()) pages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            // Mindful Reading Badge
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                Text("Sanctuary")
                                    .font(.caption.bold())
                            }
                            .foregroundColor(Color(hex: "#B39DDB"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(hex: "#B39DDB").opacity(0.12), in: Capsule())
                        }
                        
                        // Bar Chart
                        let maxVolume = max(15, (0..<7).map { tracker.pagesReadOn(dayOfWeekIndex: $0) }.max() ?? 15)
                        HStack(alignment: .bottom, spacing: 12) {
                            let days = ["M", "T", "W", "T", "F", "S", "S"]
                            ForEach(0..<7, id: \.self) { index in
                                let count = tracker.pagesReadOn(dayOfWeekIndex: index)
                                let pct = CGFloat(count) / CGFloat(maxVolume)
                                let cappedPct = count > 0 ? min(max(pct, 0.12), 1.0) : 0.04
                                
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
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            count > 0
                                                ? LinearGradient(
                                                    colors: [Color(hex: "#7B5EA7"), Color(hex: "#B39DDB")],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                                : LinearGradient(
                                                    colors: [Color.secondary.opacity(0.15), Color.secondary.opacity(0.08)],
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
                let velocity = pdfID != nil ? tracker.rollingVelocity(for: pdfID!) : 0
                let pct = totalPages > 0 ? Int(Double(currentPageIndex + 1) / Double(totalPages) * 100) : 0
                let minutes = tracker.totalMinutesReadToday()
                Logger.shared.log(
                    "ReadingStatsHUD opened for '\(bookTitle)': speed=\(String(format: "%.1f", velocity))ppm, progress=\(pct)%, timeToday=\(minutes)m",
                    category: "Reader",
                    type: .info
                )
            }
        }
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

extension Color {
    fileprivate static let emerald = Color(red: 0.1, green: 0.7, blue: 0.3)
}

