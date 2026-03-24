import SwiftUI
import Charts

struct ReadingStatsView: View {
    @StateObject private var tracker = ReaderProgressTracker.shared
    @Environment(\.presentationMode) var presentation
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Mock chart data for "This week"
    let mockWeeklyData: [(day: String, pages: Int)] = [
        ("Mon", 45), ("Tue", 120), ("Wed", 0), ("Thu", 80),
        ("Fri", 14), ("Sat", 210), ("Sun", 0)
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    
                    // Streak Header
                    HStack {
                        Image(systemName: "flame.fill").foregroundColor(.orange)
                        Text("\(tracker.readingStreak())-day streak")
                            .font(.title2).bold()
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    
                    // Weekly Chart
                    VStack(alignment: .leading) {
                        Text("This week")
                            .font(.headline)
                        
                        Chart(mockWeeklyData, id: \.day) { item in
                            BarMark(
                                x: .value("Day", item.day),
                                y: .value("Pages", item.pages)
                            )
                            .foregroundStyle(Color.blue.gradient)
                            .cornerRadius(4)
                        }
                        .frame(height: 150)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    
                    // All Time
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("All time")
                                .font(.headline)
                            Text("\(tracker.totalPagesThisWeek() * 4) pages · 23 items · \(conversionManager.collections.count) series")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    
                    // Series Progress
                    VStack(alignment: .leading) {
                        Text("Series Progress")
                            .font(.headline)
                            .padding(.bottom, 8)
                        
                        ForEach(conversionManager.collections.prefix(3)) { collection in
                            HStack {
                                Text(collection.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                
                                Spacer()
                                ZStack {
                                    Circle()
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                                    Circle()
                                        .trim(from: 0, to: tracker.seriesCompletion(collectionID: collection.id, manager: conversionManager))
                                        .stroke(Color(collection.color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                }
                                .frame(width: 24, height: 24)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
            .navigationTitle("Reading Stats")
            .navigationBarItems(trailing: Button("Done") { presentation.wrappedValue.dismiss() })
        }
    }
}
