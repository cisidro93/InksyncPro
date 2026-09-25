import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

/// Interactive intent allowing users to clear their shelf directly from the Home Screen
struct ClearShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Shelf"
    static let description = IntentDescription("Empties the active Inksync global shelf.")
    
    func perform() async throws -> some IntentResult {
        let groupDefaults = UserDefaults(suiteName: "group.com.antigravity.inksync")
        groupDefaults?.set(true, forKey: "pendingClearShelf")
        groupDefaults?.set(0, forKey: "shelfCount")
        groupDefaults?.synchronize()
        return .result()
    }
}

struct ShelfWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShelfWidgetEntry {
        ShelfWidgetEntry(
            date: Date(),
            itemsCount: 3,
            currentBookTitle: "The Great Gatsby",
            pagesLeft: 42,
            minutesToday: 24
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ShelfWidgetEntry) -> ()) {
        let entry = currentEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = currentEntry()
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
    
    private func currentEntry() -> ShelfWidgetEntry {
        let defaults = UserDefaults(suiteName: "group.com.antigravity.inksync")
        let count = defaults?.integer(forKey: "shelfCount") ?? 0
        let title = defaults?.string(forKey: "currentBookTitle")
        let pages = defaults?.integer(forKey: "currentBookPagesLeft") ?? 0
        let minutes = defaults?.integer(forKey: "minutesTodayRead") ?? 0
        
        return ShelfWidgetEntry(
            date: Date(),
            itemsCount: count,
            currentBookTitle: title,
            pagesLeft: pages,
            minutesToday: minutes
        )
    }
}

struct ShelfWidgetEntry: TimelineEntry {
    let date: Date
    let itemsCount: Int
    var currentBookTitle: String? = nil
    var pagesLeft: Int = 0
    var minutesToday: Int = 0
}

struct ShelfWidgetEntryView : View {
    var entry: ShelfWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "books.vertical.fill")
                    .foregroundColor(.purple)
                    .accessibilityHidden(true)
                Text("InkShelf")
                    .font(.headline)
                    .bold()
                Spacer()
                Text("\(entry.itemsCount)")
                    .font(.caption.bold())
                    .padding(6)
                    .background(Color.purple.opacity(0.2))
                    .clipShape(Circle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("InkShelf, \(entry.itemsCount) titles in library")
            
            if let title = entry.currentBookTitle, !title.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CURRENTLY READING")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if entry.pagesLeft > 0 {
                        Text("\(entry.pagesLeft) pages left")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if entry.minutesToday > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)
                    Text("\(entry.minutesToday)m read today")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("\(entry.minutesToday) minutes read today")
            }
            
            Spacer()
            
            if entry.itemsCount > 0 {
                Button(intent: ClearShelfIntent()) {
                    Label("Clear Shelf", systemImage: "trash")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.8))
                .accessibilityLabel("Clear Shelf")
            } else {
                Text("Your shelf is empty.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            Color.black.opacity(0.9)
        }
    }
}

struct ShelfWidget: Widget {
    let kind: String = "ShelfWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShelfWidgetProvider()) { entry in
            ShelfWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Global Shelf")
        .description("Manage your active Inksync global shelf and peaceful reading continuity right from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
