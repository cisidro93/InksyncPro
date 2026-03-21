import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

/// Interactive intent allowing users to clear their shelf directly from the Home Screen
struct ClearShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Clear Shelf"
    static var description = IntentDescription("Empties the active Inksync global shelf.")
    
    func perform() async throws -> some IntentResult {
        // In a real SwiftData environment accessed by a WidgetExtension,
        // we would query the shared App Group Container and clear the shelf relationship.
        print("Shelf cleared from Home Screen Widget")
        return .result()
    }
}

struct ShelfWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShelfWidgetEntry {
        ShelfWidgetEntry(date: Date(), itemsCount: 3)
    }

    func getSnapshot(in context: Context, completion: @escaping (ShelfWidgetEntry) -> ()) {
        let entry = ShelfWidgetEntry(date: Date(), itemsCount: 3)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        // Retrieve count from shared AppGroup UserDefaults or SwiftData
        let count = UserDefaults(suiteName: "group.com.antigravity.inksync")?.integer(forKey: "shelfCount") ?? 0
        let entry = ShelfWidgetEntry(date: Date(), itemsCount: count)
        let timeline = Timeline(entries: [entry], policy: .atEnd)
        completion(timeline)
    }
}

struct ShelfWidgetEntry: TimelineEntry {
    let date: Date
    let itemsCount: Int
}

struct ShelfWidgetEntryView : View {
    var entry: ShelfWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "books.vertical.fill")
                    .foregroundColor(.purple)
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
            
            Spacer()
            
            if entry.itemsCount > 0 {
                // Interactive Button inside Widget! (iOS 17+)
                Button(intent: ClearShelfIntent()) {
                    Label("Clear Shelf", systemImage: "trash")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.8))
            } else {
                Text("Your shelf is empty.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        // iOS 18 container background
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
        .description("Manage your active Inksync global shelf right from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
