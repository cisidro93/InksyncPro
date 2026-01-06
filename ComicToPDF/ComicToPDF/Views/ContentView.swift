import SwiftUI

struct ContentView: View {
    @StateObject var conversionManager = ConversionManager()
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Library
            LibraryView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(0)
            
            // Tab 2: Collections
            CollectionsView()
                .tabItem {
                    Label("Collections", systemImage: "folder")
                }
                .tag(1)
            
            // Tab 3: Settings
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
        .environmentObject(conversionManager)
        // Global Panel Editor Overlay
        .fullScreenCover(isPresented: $conversionManager.showingPanelEditor) {
            if let session = conversionManager.currentPanelSession {
                PanelEditorView(session: session) { resultSession in
                    conversionManager.panelEditorCompletion?(resultSession)
                    conversionManager.showingPanelEditor = false
                }
            }
        }
    }
}
