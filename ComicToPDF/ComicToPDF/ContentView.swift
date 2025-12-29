import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ConvertView()
                .tabItem {
                    Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                }
            
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
