import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var conversionManager = ConversionManager()
    @StateObject private var taskEngine = TaskEngine.shared
    @StateObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var router = AppRouter.shared
    // Wi-Fi Server for Kindle Sync
    @StateObject private var wifiServer = WiFiServer()
    
    @State private var tabBarHidden = false
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
    @State private var batchMergeSessionID = UUID()
    @State private var batchMergeItems: [ConvertedPDF] = []

    // Save & Open Workflow
    @State private var showingWebExport = false
    @State private var webExportPDF: ConvertedPDF?

    // UI Mode
    @AppStorage("appUIMode") private var appUIMode: AppUIMode = .pro
    @State private var showingSettingsInspector = false



    // Universal Error State
    @State private var showingGlobalError = false
    @State private var globalErrorMessage = ""
    @State private var globalErrorCategory = "System"

    var body: some View {
        ZStack {
            NeuralExpressiveBackground()
            
            ZStack {
                // Tab 0: Library
                NavigationStack(path: $router.path) {
                    ModernLibraryView(
                        selectedPDF: $selectedPDF,
                        isBatchMode: $isBatchMode,
                        multiSelection: $multiSelection,
                        showingBatchMergeReorder: $showingBatchMergeReorder,
                        batchMergeItems: $batchMergeItems,
                        useNavigationStack: true,
                        onFolderImport: {
                            AppRouter.shared.presentSheet(.importQueue)
                        }
                    )
                    .navigationDestination(for: ConvertedPDF.self) { pdf in
                        ConvertView(pdf: pdf).id(pdf.id)
                    }
                }
                .tabVisible(router.selectedTab == 0)
                
                // Tab 1: Workspace
                WorkspaceView(isSheet: false)
                    .environmentObject(conversionManager)
                    .tabVisible(router.selectedTab == 1)
                
                // Tab 2: Devices
                DevicesView()
                    .environmentObject(conversionManager)
                    .environmentObject(PeerManager.shared)
                    .tabVisible(router.selectedTab == 2)
            }
            
            // iPad Progress Panel Overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    iPadProgressPanel
                        .frame(width: 320)
                        .padding(.trailing, 24)
                        .padding(.bottom, 100) // Above OmniDock
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !tabBarHidden && !isBatchMode {
                InkTabBar(
                    selectedTab: $router.selectedTab,
                    isHidden: $tabBarHidden,
                    convertingProgress: conversionManager.conversionProgress,
                    isConverting: conversionManager.isConverting,
                    convertingMessage: conversionManager.processingStatus,
                    isImporting: ImportMonitorManager.shared.isImporting,
                    importProgress: ImportMonitorManager.shared.progress,
                    importMessage: "Importing..."
                )
                .padding(.bottom, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InkTabBar_Hide"))) { _ in
            withAnimation { tabBarHidden = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InkTabBar_Show"))) { _ in
            withAnimation { tabBarHidden = false }
        }
        .secureVaultPrivacy()
        .environmentObject(conversionManager)
        .environmentObject(settingsManager)
        .environmentObject(wifiServer)
        .environmentObject(SecurityManager.shared)
        .environmentObject(PeerManager.shared)
        .environment(\.dynamicTypeSize, settingsManager.conversionSettings.textSize.swiftUIValue)
        .sheet(item: $pdfToShare) { pdf in ShareSheet(activityItems: [pdf.url]) }
        .alert(item: $taskEngine.appAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            LinkedLibraryScanner.shared.conversionManager = conversionManager
            AnnotationStore.shared.initialize(with: modelContext)
            PageModelStore.shared.initialize(with: modelContext)
            
            Task { @MainActor in
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                let _ = MigrationService.shared.performSmartGrouping(context: modelContext)
                
                // Always fetch the latest SwiftData on startup to ensure conversionManager matches the DB.
                if let (sdPdfs, sdCols) = try? await MigrationService.shared.fetchSwiftDataLegacyBridge() {
                    conversionManager.convertedPDFs = sdPdfs.map { $0.toDTO() }
                    conversionManager.collections = sdCols.map { $0.toDTO() }
                }
                
                await SandboxCleanupManager.shared.passiveScan()
            }
        }
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
        .sheet(isPresented: $showingBatchMergeReorder) {
            LazyView {
                SeriesMergeConfigurationView(sourceFiles: batchMergeItems)
                    .id(batchMergeSessionID)
                    .environmentObject(conversionManager)
                    .environmentObject(settingsManager)
            }
        }
        .onChange(of: showingBatchMergeReorder) { _, newValue in
            if newValue {
                batchMergeSessionID = UUID()
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await ReaderImageFilterEngine.shared.purgeCache() }
            Logger.shared.log("⚠️ Memory warning received — purged ReaderImageFilterEngine cache.", category: "Memory", type: .warning)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToLibraryTab"))) { _ in
            // No-op
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowSettingsInspector"))) { _ in
            showingSettingsInspector = true
        }
        .modifier(iPadKeyboardShortcuts(
            selectedTab: $router.selectedTab,
            showImport: $showingWebExport,
            showingSettingsInspector: $showingSettingsInspector,
            showingBatchMergeReorder: $showingBatchMergeReorder,
            pdfToShare: $pdfToShare,
            pdfToEdit: $pdfToEdit
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
                            
                            _ = await ImportQueueManager.shared.stageWithDuplicateCheck([url])
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettingsInspector) {
            NavigationStack {
                SettingsView()
                    .environmentObject(conversionManager)
                    .environmentObject(settingsManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettingsInspector = false }.bold()
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationCornerRadius(32)
            .presentationDragIndicator(.visible)
        }
        .environmentObject(router)
    }

    private var iPadProgressPanel: some View {
        let isConverting  = conversionManager.isConverting
        let isImporting   = ImportMonitorManager.shared.isImporting
        let isActive      = isConverting || isImporting

        let progress: Double = {
            if isImporting  { return ImportMonitorManager.shared.progress }
            if isConverting { return conversionManager.conversionProgress }
            return 0
        }()

        let label: String = {
            if isImporting {
                let done  = ImportMonitorManager.shared.filesProcessed
                let total = ImportMonitorManager.shared.totalFilesToProcess
                return "Importing \(done) / \(total)"
            }
            if isConverting {
                let msg = conversionManager.processingStatus
                return msg.isEmpty ? "Converting…" : msg
            }
            return ""
        }()

        return Group {
            if isActive {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        Text(progress < 0.01 && progress > 0 ? "<1%" : "\(Int(progress * 100))%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: progress)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.1))
                                .frame(height: 4)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.55)],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * max(0.02, progress), height: 4)
                                .animation(.easeInOut(duration: 0.35), value: progress)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.75)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
            }
        }
    }
}




