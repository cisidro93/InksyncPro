import SwiftUI

struct ContentView: View {
    @StateObject private var conversionManager = ConversionManager()
    @StateObject private var themeManager = ThemeManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showingOnboarding = false
    @State private var selectedTab = 0
    
    // Panel Editor State
    @State private var showPanelEditor = false
    @State private var panelEditSession: PanelEditSession?
    @State private var panelEditorCompletion: ((PanelEditSession?) -> Void)?
    
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
        .sheet(isPresented: $showPanelEditor) {
            if let session = panelEditSession, let completion = panelEditorCompletion {
                PanelEditorView(
                    session: session,
                    onComplete: { updatedSession in completion(updatedSession) },
                    onCancel: { completion(nil) }
                )
            }
        }
        .onChange(of: conversionManager.showingPanelEditor) { newValue in
            if newValue {
                self.panelEditSession = conversionManager.currentPanelSession
                self.panelEditorCompletion = conversionManager.panelEditorCompletion
                self.showPanelEditor = true
            } else {
                self.showPanelEditor = false
            }
        }
    }
}
