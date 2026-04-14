import SwiftUI
import Charts

struct ReadingStatsView: View {
    @ObservedObject private var tracker = ReaderProgressTracker.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    
                    // ── Streak & Daily Goal ──────────────────────────────
                    HStack(spacing: 16) {
                        StatCard(
                            icon: "flame.fill",
                            iconColor: .orange,
                            title: "\(tracker.readingStreak())",
                            subtitle: "Day Streak"
                        )
                        
                        StatCard(
                            icon: "book.fill",
                            iconColor: Theme.blue,
                            title: "\(totalPagesRead)",
                            subtitle: "Pages Read"
                        )
                        
                        StatCard(
                            icon: "books.vertical.fill",
                            iconColor: .purple,
                            title: "\(totalItemsStarted)",
                            subtitle: "Items Started"
                        )
                    }
                    
                    // ── Weekly Activity Chart ────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This Week")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.text)
                        
                        Chart(weeklyData, id: \.day) { item in
                            BarMark(
                                x: .value("Day", item.day),
                                y: .value("Pages", item.pages)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.blue, Theme.purple],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .cornerRadius(6)
                        }
                        .frame(height: 160)
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                                    .foregroundStyle(Color.gray.opacity(0.3))
                                AxisValueLabel()
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .chartXAxis {
                            AxisMarks { _ in
                                AxisValueLabel()
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )
                    
                    // ── Library Overview ─────────────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Library Overview")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.text)
                        
                        HStack {
                            OverviewStat(label: "Total Files", value: "\(conversionManager.convertedPDFs.count)")
                            Divider().frame(height: 30)
                            OverviewStat(label: "Total Pages", value: "\(totalLibraryPages)")
                            Divider().frame(height: 30)
                            OverviewStat(label: "Series", value: "\(totalSeries)")
                        }
                        
                        HStack {
                            OverviewStat(label: "Completed", value: "\(completedBooks)")
                            Divider().frame(height: 30)
                            OverviewStat(label: "In Progress", value: "\(inProgressBooks)")
                            Divider().frame(height: 30)
                            OverviewStat(label: "Unread", value: "\(unreadBooks)")
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )
                    
                    // ── Series Completion Rings ──────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Series Progress")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.text)
                        
                        let seriesGroups = buildSeriesGroups()
                        
                        if seriesGroups.isEmpty {
                            Text("No series with reading data yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(seriesGroups, id: \.name) { series in
                                HStack(spacing: 12) {
                                    // Completion ring
                                    ZStack {
                                        Circle()
                                            .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                                        Circle()
                                            .trim(from: 0, to: CGFloat(series.progress))
                                            .stroke(
                                                series.progress >= 1.0 ? Color.green : Theme.blue,
                                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                            )
                                            .rotationEffect(.degrees(-90))
                                    }
                                    .frame(width: 32, height: 32)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(series.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .lineLimit(1)
                                        Text("\(series.readCount)/\(series.totalCount) issues read")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text("\(Int(series.progress * 100))%")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundColor(series.progress >= 1.0 ? .green : Theme.textSecondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )
                    
                    // ── Format Distribution ──────────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Format Distribution")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.text)
                        
                        let formatData = buildFormatDistribution()
                        
                        Chart(formatData, id: \.format) { item in
                            SectorMark(
                                angle: .value("Count", item.count),
                                innerRadius: .ratio(0.5),
                                angularInset: 2
                            )
                            .foregroundStyle(item.color)
                            .annotation(position: .overlay) {
                                Text("\(item.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(height: 180)
                        
                        // Legend
                        HStack(spacing: 16) {
                            ForEach(formatData, id: \.format) { item in
                                HStack(spacing: 4) {
                                    Circle().fill(item.color).frame(width: 8, height: 8)
                                    Text(item.format)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
            .navigationTitle("Reading Stats")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }
    
    // MARK: - Computed Data
    
    var totalPagesRead: Int {
        conversionManager.convertedPDFs
            .compactMap { $0.metadata.lastReadPage }
            .reduce(0, +)
    }
    
    var totalItemsStarted: Int {
        conversionManager.convertedPDFs
            .filter { ($0.metadata.lastReadPage ?? 0) > 0 }
            .count
    }
    
    var totalLibraryPages: Int {
        conversionManager.convertedPDFs
            .reduce(0) { $0 + $1.pageCount }
    }
    
    var totalSeries: Int {
        Set(conversionManager.convertedPDFs.compactMap { $0.metadata.series }).count
    }
    
    var completedBooks: Int {
        conversionManager.convertedPDFs
            .filter { $0.metadata.lastReadPage == $0.pageCount && $0.pageCount > 0 }
            .count
    }
    
    var inProgressBooks: Int {
        conversionManager.convertedPDFs
            .filter { ($0.metadata.lastReadPage ?? 0) > 0 && $0.metadata.lastReadPage != $0.pageCount }
            .count
    }
    
    var unreadBooks: Int {
        conversionManager.convertedPDFs
            .filter { ($0.metadata.lastReadPage ?? 0) == 0 }
            .count
    }
    
    var weeklyData: [(day: String, pages: Int)] {
        let cal = Calendar.current
        // Build locale-correct day names starting from firstWeekday
        var symbols = cal.shortWeekdaySymbols  // Sunday-first always
        let firstIdx = cal.firstWeekday - 1     // 0=Sun in the array
        symbols = Array(symbols[firstIdx...] + symbols[..<firstIdx])

        return symbols.enumerated().map { idx, name in
            let pagesForDay = tracker.pagesReadOn(dayOfWeekIndex: (idx + firstIdx) % 7)
            return (day: name, pages: pagesForDay)
        }
    }
    
    struct SeriesProgress {
        let name: String
        let readCount: Int
        let totalCount: Int
        var progress: Double {
            guard totalCount > 0 else { return 0 }
            return Double(readCount) / Double(totalCount)
        }
    }
    
    func buildSeriesGroups() -> [SeriesProgress] {
        var groups: [String: (read: Int, total: Int)] = [:]
        
        for pdf in conversionManager.convertedPDFs {
            if let series = pdf.metadata.series, !series.isEmpty {
                let isRead = (pdf.metadata.lastReadPage ?? 0) > 0
                groups[series, default: (0, 0)].total += 1
                if isRead { groups[series, default: (0, 0)].read += 1 }
            }
        }
        
        return groups
            .map { SeriesProgress(name: $0.key, readCount: $0.value.read, totalCount: $0.value.total) }
            // Sort by most books read (engagement) then alphabetically
            .sorted { lhs, rhs in
                if lhs.readCount != rhs.readCount { return lhs.readCount > rhs.readCount }
                return lhs.name < rhs.name
            }
            .prefix(10)
            .map { $0 }
    }
    
    struct FormatItem {
        let format: String
        let count: Int
        let color: Color
    }
    
    func buildFormatDistribution() -> [FormatItem] {
        var counts: [String: Int] = [:]
        for pdf in conversionManager.convertedPDFs {
            let ext = pdf.fileExtensionString.uppercased()
            counts[ext.isEmpty ? "PDF" : ext, default: 0] += 1
        }
        
        let colors: [Color] = [Theme.blue, Theme.orange, .purple, .green, .pink, .teal]
        return counts.sorted { $0.value > $1.value }.enumerated().map { idx, item in
            FormatItem(format: item.key, count: item.value, color: colors[idx % colors.count])
        }
    }
}

// MARK: - Subcomponents

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(iconColor)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }
}

private struct OverviewStat: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
