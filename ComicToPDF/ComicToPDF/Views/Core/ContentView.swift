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
    @ObservedObject private var router = AppRouter.shared
    // Wi-Fi Server for Kindle Sync
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

    // Save & Open Workflow
    @State private var showingWebExport = false
    @State private var webExportPDF: ConvertedPDF?

    // UI Mode
    @AppStorage("appUIMode") private var appUIMode: AppUIMode = .pro
    @AppStorage("useSidebar") private var useSidebar = true
    @State private var showingSettingsInspector = false



    // Universal Error State
    @State private var showingGlobalError = false
    @State private var globalErrorMessage = ""
    @State private var globalErrorCategory = "System"

    var body: some View {
        ZStack {
            NeuralExpressiveBackground()
            
            NavigationStack(path: $router.path) {
                ModernLibraryView(
                    selectedPDF: $selectedPDF,
                    isBatchMode: $isBatchMode,
                    multiSelection: $multiSelection,
                    showingBatchMergeReorder: $showingBatchMergeReorder,
                    batchMergeItems: $batchMergeItems,
                    useNavigationStack: true,
                    onFolderImport: {
                        ImportCoordinator.present(type: .files) { urls in
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
        .onAppear {
            LinkedLibraryScanner.shared.conversionManager = conversionManager
            AnnotationStore.shared.initialize(with: modelContext)
            PageModelStore.shared.initialize(with: modelContext)
            
            Task { @MainActor in
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                MigrationService.shared.runZettelkastenNLPBackfill(context: modelContext)
                let genCount = MigrationService.shared.performSmartGrouping(context: modelContext)
                
                if genCount > 0 {
                    if let (sdPdfs, sdCols) = try? await MigrationService.shared.fetchSwiftDataLegacyBridge() {
                        conversionManager.convertedPDFs = sdPdfs.map { $0.toDTO() }
                        conversionManager.collections = sdCols.map { $0.toDTO() }
                    }
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
            selectedTab: .constant(0),
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
                                _ = ImportQueueManager.shared.stageWithDuplicateCheck([url])
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettingsInspector) {
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




