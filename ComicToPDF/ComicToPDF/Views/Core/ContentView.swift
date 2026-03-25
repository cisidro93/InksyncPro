import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    
    @StateObject private var conversionManager = ConversionManager()
    @StateObject private var wifiServer = WiFiServer()
    @StateObject private var peerManager = PeerManager.shared
    
    @State private var selectedTab = 0
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    
    // Universal Alerts
    @State private var showingGlobalError = false
    @State private var globalErrorMessage = ""

    @State private var showSmartImport = false
    
    // MARK: - Adaptive root navigation
    var body: some View {
        Group {
            if #available(iOS 18, *) {
                adaptiveTabView_iOS18
            } else {
                adaptiveTabView_legacy
            }
        }
        .preferredColorScheme(.dark)
        .secureVaultPrivacy()
        .modifier(iPadKeyboardShortcuts(
            selectedTab: $selectedTab,
            showImport: $showSmartImport
        ))
        .fileImporter(
            isPresented: $showSmartImport,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            // Root-level global file importer via keyboard shortcut
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: url, to: dest)
                if accessing { url.stopAccessingSecurityScopedResource() }
                
                // Switch to import tab so we can intercept it cleanly, 
                // or we could show a global sheet. For now, we will 
                // rely on the user having to switch manually if we don't have a global sheet state.
                selectedTab = 2
            }
        }
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
    
    // iOS 18+: sidebar tab style (iPad shows rail/sidebar, iPhone shows bottom bar)
    @available(iOS 18, *)
    private var adaptiveTabView_iOS18: some View {
        TabView(selection: $selectedTab) {
            Tab("Read Now", systemImage: "book.open.fill", value: 0) {
                ReadNowView()
            }
            Tab("Library", systemImage: "books.vertical.fill", value: 1) {
                InkLibraryView()
            }
            Tab("Import", systemImage: "arrow.down.circle.fill", value: 2) {
                ImportTriggerView()
            }
            Tab("Devices", systemImage: "ipad.and.iphone", value: 3) {
                DevicesView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(.inkBlue)
    }

    // iOS 16–17: manual adaptation
    private var adaptiveTabView_legacy: some View {
        if hSizeClass == .regular {
            // iPad on iOS 16-17: use NavigationSplitView with manual sidebar
            return AnyView(iPadRootSplitView(selectedTab: $selectedTab))
        } else {
            // iPhone: standard bottom tab bar
            return AnyView(iPhoneTabView)
        }
    }

    private var iPhoneTabView: some View {
        TabView(selection: $selectedTab) {
            ReadNowView()
                .tabItem { Label("Read Now", systemImage: "book.open.fill") }
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
    }
}


