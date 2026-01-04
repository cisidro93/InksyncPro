import SwiftUI

struct ContentView: View {
    @StateObject private var conversionManager = ConversionManager()
    @StateObject private var themeManager = ThemeManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showingOnboarding = false
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ConvertView().tabItem { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }.tag(0)
            LibraryView(selectedTab: $selectedTab).tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(1)
            CollectionsView().tabItem { Label("Collections", systemImage: "folder.fill") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(.orange)
        .environmentObject(conversionManager)
        .environmentObject(themeManager)
        .preferredColorScheme(themeManager.selectedTheme.colorScheme)
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView()
                .onDisappear {
                    hasCompletedOnboarding = true
                }
        }
        .onAppear {
            if !hasCompletedOnboarding {
                showingOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $conversionManager.showingPanelEditor) {
            if let session = conversionManager.currentPanelSession {
                PanelEditorView(session: session) { result in
                    conversionManager.panelEditorCompletion?(result)
                }
            } else {
                Text("Error: No session")
            }
        }
    }
}
