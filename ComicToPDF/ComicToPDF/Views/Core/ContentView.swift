import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
    // ✅ NEW: Wi-Fi Server for Kindle Sync
    @StateObject private var wifiServer = WiFiServer()
    
    @State private var selectedTab = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedPDF: ConvertedPDF?
    
    // Global Sheets
    @State private var pdfToShare: ConvertedPDF?
    @State private var pdfToEdit: ConvertedPDF?
    @State private var showingLargeFileAlert = false
    @State private var largeFilePDF: ConvertedPDF?
    
    // Batch Mode State (Hoisted)
    @State private var isBatchMode = false
    @State private var multiSelection = Set<UUID>()
    @State private var showingBatchMergeReorder = false
    @State private var batchMergeItems: [ConvertedPDF] = []
    
    // ✅ New State for "Save & Open Workflow"
    @State private var showingWebExport = false
    @State private var webExportPDF: ConvertedPDF?
    
    // ✅ Onboarding State
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    
    // ✅ UI Mode State
    @AppStorage("appUIMode") private var appUIMode: AppUIMode = .pro
    
    // ✅ iPad Layout Toggles
    @AppStorage("useSidebar") private var useSidebar = true
    @State private var showingSettingsInspector = false
    // (columnVisibility managed above)

    var body: some View {
        VStack(spacing: 0) {
            // ✅ Global "Go vs Pro" Mode Switcher
            HStack {
                Spacer()
                Picker("UI Mode", selection: $appUIMode) {
                    Text("Go Mode").tag(AppUIMode.go)
                    Text("Pro Mode").tag(AppUIMode.pro)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
            .zIndex(1)
            
            ZStack {
                if appUIMode == .go {
                    GoConvertView()
                        .transition(.opacity)
                } else {
                    if sizeClass == .compact || !useSidebar {
                        liquidGlassLayout
                            .transition(.opacity)
                    } else {
                        iPadLayout
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut, value: appUIMode)
        }
        .secureVaultPrivacy()
        .environmentObject(conversionManager)
        .environmentObject(wifiServer)
        .environmentObject(SecurityManager.shared)
        .environment(\.dynamicTypeSize, conversionManager.conversionSettings.textSize.swiftUIValue)
        .sheet(item: $pdfToShare) { pdf in ShareSheet(activityItems: [pdf.url]) }
        .alert(item: $conversionManager.appAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onAppear {
            if !hasSeenOnboarding {
                showOnboarding = true
            }
            Task { @MainActor in
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                MigrationService.shared.performSmartGrouping(context: modelContext)
            }
        }
        // Layer 3: Post-import series grouping prompt
        .sheet(item: $conversionManager.pendingSeriesGroup) { group in
            SeriesGroupingSheet(
                importedPDFs: group.pdfs,
                suggestedName: group.suggestedName,
                onConfirm: { seriesName in
                    Task { await conversionManager.finalizeSeriesImport(pdfs: group.pdfs, seriesName: seriesName) }
                },
                onSkip: {
                    conversionManager.pendingSeriesGroup = nil
                }
            )
        }
    }

    // ✅ iOS 26 "Liquid Glass" Layout
    var liquidGlassLayout: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Library
            NavigationStack {
                ModernLibraryView(
                    selectedPDF: $selectedPDF,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    showingBatchMergeReorder: $showingBatchMergeReorder,
                    batchMergeItems: $batchMergeItems,
                    useNavigationStack: true,
                    onFolderImport: {
                        FolderImportCoordinator.present { urls in
                            guard !urls.isEmpty else { return }
                            Task { await conversionManager.importFilesAsSeries(urls: urls) }
                        }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ConvertedPDF.self) { pdf in
                    ConvertView(pdf: pdf)
                        .id(pdf.id)
                }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(0)
            
            // Tab 2: Removed Template Vault per request
            
            // Tab 3: Search (New System Role)
            Text("Global Search")
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(3) // Search is typically 0 or specialized, putting securely at 3
            
            // Tab 4: Work Area
            NavigationStack {
                EditorDashboardView()
            }
            .tabItem { Label("Work Area", systemImage: "pencil.and.outline") }
            .tag(4)
            
            // Tab 5: Settings
            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(5)
        }
        // ✅ iOS 26 Enhancements
        .ios26_tabBarMinimizeBehavior(.onScrollDown)
        .ios26_tabViewBottomAccessory {
            if conversionManager.isConverting {
                ProgressOverlay(
                    progress: conversionManager.conversionProgress,
                    message: conversionManager.processingStatus
                )
            }
        }
    }
    
    var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                let tabBinding = Binding<Int?>(
                    get: { selectedTab },
                    set: { selectedTab = $0 ?? 0 }
                )
                List(selection: tabBinding) {
                    NavigationLink(value: 0) {
                        Label("Library", systemImage: "books.vertical.fill")
                    }
                    // Templates removed per request
                    NavigationLink(value: 2) {
                        Label("Work Area", systemImage: "pencil.and.outline")
                    }
                }
                .navigationTitle("Inksync")
                
                Spacer()
                
                // Settings button at the bottom of the sidebar
                Button(action: {
                    showingSettingsInspector.toggle()
                }) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Settings")
                        Spacer()
                    }
                    .padding()
                    .foregroundColor(.white)
                }
            }
        } detail: {
            NavigationStack {
                if selectedTab == 0 {
                    ModernLibraryView(
                        selectedPDF: $selectedPDF,
                        isBatchMode: $isBatchMode,
                        multiSelection: $multiSelection,
                        showingBatchMergeReorder: $showingBatchMergeReorder,
                        batchMergeItems: $batchMergeItems,
                        useNavigationStack: false, // Handle selection manually in detail if needed, but since we are the detail, maybe we DO want navigation stack inside it for reader? Actually, ModernLibraryView already handles `useNavigationStack: false` by setting `selectedPDF`.
                        onFolderImport: {
                            FolderImportCoordinator.present { urls in
                                guard !urls.isEmpty else { return }
                                Task { await conversionManager.importFilesAsSeries(urls: urls) }
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    // If a PDF is selected, we want to push the ConvertView. 
                    // To do this cleanly without breaking the grid, we use a navigationDestination bounded to selectedPDF
                    .navigationDestination(isPresented: Binding(
                        get: { selectedPDF != nil },
                        set: { if !$0 { selectedPDF = nil } }
                    )) {
                        if let pdf = selectedPDF {
                            ConvertView(pdf: pdf)
                        }
                    }
                } else if selectedTab == 1 {
                    // Templates View Removed. Fallback to EmptyView if state was saved.
                    Text("Templates Feature Temporarily Removed")
                        .foregroundColor(.secondary)
                } else if selectedTab == 2 {
                    EditorDashboardView()
                }
            }
            // ✅ iPad Settings Inspector
            .inspector(isPresented: $showingSettingsInspector) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettingsInspector = false }.bold()
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .inspectorColumnWidth(min: 300, ideal: 350, max: 400)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}


