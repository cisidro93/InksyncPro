import SwiftUI

struct ContentView: View {
    @StateObject private var conversionManager = ConversionManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ConvertView().tabItem { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }.tag(0)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(1)
            CollectionsView().tabItem { Label("Collections", systemImage: "folder.fill") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(.orange)
        .environmentObject(conversionManager)
        .fullScreenCover(isPresented: !$hasCompletedOnboarding) {
            OnboardingView()
        }
    }
}
