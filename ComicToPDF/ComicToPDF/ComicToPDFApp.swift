import SwiftData

@main
struct InksyncProApp: App {
    var body: some Scene {
        WindowGroup { 
            ContentView()
                .environmentObject(ConversionManager())
                .modelContainer(for: [ComicBook.self, Page.self, Panel.self], isUndoEnabled: true)
        }
    }
}
