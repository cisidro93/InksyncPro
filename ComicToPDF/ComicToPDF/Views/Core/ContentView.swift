import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var conversionManager = ConversionManager()
    @StateObject private var settingsManager = AppSettingsManager.shared
    // ✅ NEW: Wi-Fi Server for Kindle Sync
    @StateObject private var wifiServer = WiFiServer()
    
    @State private var selectedTab = 0   // 0 = Library (default launch tab)
    @State private var tabBarHidden = false
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
    
    // ✅ PHASE 8: Universal Alerts
    @State private var showingGlobalError = false
    @State private var globalErrorMessage = ""
    @State private var globalErrorCategory = "System"

    var body: some View {
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
        .secureVaultPrivacy()
        .environmentObject(conversionManager)
        .environmentObject(settingsManager)
        .environmentObject(wifiServer)
        .environmentObject(SecurityManager.shared)
        .environment(\.dynamicTypeSize, settingsManager.conversionSettings.textSize.swiftUIValue)
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
            // ✅ CRITICAL: Wire LinkedLibraryScanner to this live ConversionManager instance.
            // The scanner holds a weak ref — this must be set here where the @StateObject lives.
            LinkedLibraryScanner.shared.conversionManager = conversionManager
            // Bind legacy memory-cache mapping to active SwiftData context
            AnnotationStore.shared.initialize(with: modelContext)
            PageModelStore.shared.initialize(with: modelContext)
            
            Task { @MainActor in
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                let genCount = MigrationService.shared.performSmartGrouping(context: modelContext)
                
                // SILENT CACHE SYNC: We MUST reload SwiftData into RAM so that any new natively-generated
                // collections aren't destroyed continuously by the next stale UI `save()` call.
                if genCount > 0 {
                    if let (sdPdfs, sdCols) = try? await MigrationService.shared.fetchSwiftDataLegacyBridge() {
                        conversionManager.convertedPDFs = sdPdfs.map { $0.toDTO() }
                        conversionManager.collections = sdCols.map { $0.toDTO() }
                    }
                }
                
                // Passive scan for sandbox cleanup badge in Settings
                await SandboxCleanupManager.shared.passiveScan()
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
        .sheet(isPresented: $conversionManager.isPresentingPanelEditor) {
            if let img = conversionManager.currentEditorImage {
                PanelEditorView(
                    image: img,
                    panels: $conversionManager.currentEditorPanels,
                    onDone: { editedRects in
                        conversionManager.submitPanelEdits(editedRects)
                    }
                )
            }
        }
        // ✅ PHASE 8: Educational Alert Trap
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalErrorTriggered"))) { notification in
            if let userInfo = notification.userInfo,
               let message = userInfo["message"] as? String,
               let category = userInfo["category"] as? String {
                self.globalErrorCategory = category
                self.globalErrorMessage = message
                self.showingGlobalError = true
            }
        }
        .alert("\(globalErrorCategory) Component Failure", isPresented: $showingGlobalError) {
            Button("Copy Diagnostic Code") { UIPasteboard.general.string = "[\(globalErrorCategory)] \(globalErrorMessage)" }
            Button("Dismiss", role: .cancel) { }
        } message: {
            Text("\(globalErrorMessage)\n\nA trace has been recorded. Navigate to Settings ➔ Logs and filter by '\(globalErrorCategory)' to export the failure context to Support.")
        }
        // ✅ Hardware Shortcuts
        .modifier(iPadKeyboardShortcuts(
            selectedTab: $selectedTab,
            showImport: $showingWebExport
        ))
        .onChange(of: showingWebExport) { _, showing in
            if showing {
                showingWebExport = false
                ImportCoordinator.present(type: .files) { urls in
                    if let url = urls.first {
                        let accessing = url.startAccessingSecurityScopedResource()
                        
                        Task.detached(priority: .userInitiated) {
                            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                            
                            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                            try? FileManager.default.removeItem(at: dest)
                            
                            var coordError: NSError?
                            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { safeURL in
                                try? FileManager.default.copyItem(at: safeURL, to: dest)
                            }
                            
                            await MainActor.run {
                                self.selectedTab = 2 // Switch to Inbox Tab
                            }
                        }
                    }
                }
            }
        }
    }

    // ✅ iOS + iPad Layout — Pure Custom Tab Router (NO TabView = NO native tab bar)
    var liquidGlassLayout: some View {
        ZStack(alignment: .bottom) {

            // ── Content Layer ──────────────────────────────────────────────────
            // Each child stays alive (preserves scroll position / nav stack) but
            // is hidden when not active. This avoids the blank-flash on first switch.
            Group {
                // Tab 0: Library
                NavigationStack {
                    ModernLibraryView(
                        selectedPDF: $selectedPDF,
                        isBatchMode: $isBatchMode,
                        multiSelection: $multiSelection,
                        showingBatchMergeReorder: $showingBatchMergeReorder,
                        batchMergeItems: $batchMergeItems,
                        useNavigationStack: true,
                        onFolderImport: {
                            ImportCoordinator.present(type: .folder) { urls in
                                guard !urls.isEmpty else { return }
                                _ = ImportQueueManager.shared.stageWithDuplicateCheck(urls)
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: ConvertedPDF.self) { pdf in
                        ConvertView(pdf: pdf).id(pdf.id)
                    }
                }
                .tabVisible(selectedTab == 0)

                // Tab 1: Reader Dashboard
                NavigationStack { ActiveReaderDashboardView() }
                    .tabVisible(selectedTab == 1)

                // Tab 2: Inbox
                NavigationStack { InboxReviewView() }
                    .tabVisible(selectedTab == 2)

                // Tab 3: Devices
                DevicesView()
                    .tabVisible(selectedTab == 3)

                // Tab 4: Work Area
                NavigationStack { EditorDashboardView() }
                    .tabVisible(selectedTab == 4)

                // Tab 5: Highlights
                NavigationStack { GlobalZettelkastenHubView() }
                    .tabVisible(selectedTab == 5)

                // Tab 6: Settings
                NavigationStack { SettingsView() }
                    .tabVisible(selectedTab == 6)
            }
            // Reserve space at the bottom so content scrolls above the pill.
            // Use a smaller inset in landscape where screen height is precious.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: (sizeClass == .compact && verticalSizeClass == .compact) ? 50 : 80)
            }

            // ── Floating Glass Pill ────────────────────────────────────────────
            InkTabBar(
                selectedTab: $selectedTab,
                isHidden: $tabBarHidden,
                convertingProgress: max(conversionManager.conversionProgress, ImportMonitorManager.shared.progress),
                isConverting: conversionManager.isConverting,
                convertingMessage: conversionManager.processingStatus
            )
            .padding(.bottom, 12)
        }
        .ignoresSafeArea(edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InkTabBar_Hide"))) { _ in
            withAnimation { tabBarHidden = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InkTabBar_Show"))) { _ in
            withAnimation { tabBarHidden = false }
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
                    NavigationLink(value: 1) {
                        Label("Reader", systemImage: "book.fill")
                    }
                    NavigationLink(value: 2) {
                        Label("Inbox", systemImage: "tray.full.fill")
                    }
                    NavigationLink(value: 3) {
                        Label("Devices", systemImage: "ipad.and.iphone")
                    }
                    NavigationLink(value: 4) {
                        Label("Work Area", systemImage: "scissors")
                    }
                    NavigationLink(value: 5) {
                        Label("Highlights", systemImage: "text.badge.star")
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
                    .foregroundColor(.primary)
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
                        useNavigationStack: false,
                        onFolderImport: {
                            ImportCoordinator.present(type: .folder) { urls in
                                guard !urls.isEmpty else { return }
                                Task { await conversionManager.importFilesAsSeries(urls: urls) }
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(isPresented: Binding(
                        get: { selectedPDF != nil },
                        set: { if !$0 { selectedPDF = nil } }
                    )) {
                        if let pdf = selectedPDF { ConvertView(pdf: pdf) }
                    }
                } else if selectedTab == 1 {
                    ActiveReaderDashboardView()
                } else if selectedTab == 2 {
                    InboxReviewView()
                } else if selectedTab == 3 {
                    DevicesView()
                } else if selectedTab == 4 {
                    EditorDashboardView()
                } else if selectedTab == 5 {
                    NavigationStack {
                        GlobalZettelkastenHubView()
                    }
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


