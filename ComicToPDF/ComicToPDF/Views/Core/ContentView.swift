import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) var sizeClass
    
    @StateObject private var conversionManager = ConversionManager()
    @StateObject private var wifiServer = WiFiServer()
    @StateObject private var peerManager = PeerManager.shared
    
    @State private var selectedTab = 0
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    
    // Universal Alerts
    @State private var showingGlobalError = false
    @State private var globalErrorMessage = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            ReadNowView()
                .tabItem { Label("Read Now", systemImage: "book.pages") }
                .tag(0)

            InkLibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(1)

            ImportTriggerView()
                .tabItem { Label("Import", systemImage: "arrow.down.circle.fill") }
                .tag(2)

            DevicesView()
                .tabItem { Label("Devices", systemImage: "ipad.and.iphone") }
                .tag(3)
        }
        .tint(.inkBlue)
        .preferredColorScheme(.dark)
        .secureVaultPrivacy()
        .environmentObject(conversionManager)
        .environmentObject(wifiServer)
        .environmentObject(peerManager)
        .environmentObject(SecurityManager.shared)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onAppear {
            if !hasSeenOnboarding {
                showOnboarding = true
            }
            peerManager.startDiscovery()
            Task { @MainActor in
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                MigrationService.shared.performSmartGrouping(context: modelContext)
            }
        }
        // Universal Alert Trap
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalErrorTriggered"))) { notification in
            if let userInfo = notification.userInfo,
               let message = userInfo["message"] as? String,
               let category = userInfo["category"] as? String {
                self.globalErrorMessage = "[\(category)]\n\(message)"
                self.showingGlobalError = true
            }
        }
        .alert("System Error", isPresented: $showingGlobalError) {
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text(globalErrorMessage)
        }
    }
}


