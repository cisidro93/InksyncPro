import SwiftData

@main
struct InksyncProApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup { 
            ContentView()
                .environmentObject(ConversionManager())
                .modelContainer(for: [ComicBook.self, Page.self, Panel.self], isUndoEnabled: true)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background, .inactive:
                         SecurityManager.shared.handleAppBackgrounding()
                    case .active:
                         SecurityManager.shared.handleAppForegrounding()
                    @unknown default: break
                    }
                }
        }
    }
}
