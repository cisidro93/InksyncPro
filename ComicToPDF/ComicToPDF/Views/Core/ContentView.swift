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
        Group {
            if useSidebar && sizeClass == .regular {
                iPadLayout
            } else {
                liquidGlassLayout
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
            // Wire LinkedLibraryScanner to this live ConversionManager instance.
            LinkedLibraryScanner.shared.conversionManager = conversionManager
            // Bind legacy memory-cache mapping to active SwiftData context
            AnnotationStore.shared.initialize(with: modelContext)
            PageModelStore.shared.initialize(with: modelContext)
            
            Task { @MainActor in
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                MigrationService.shared.runZettelkastenNLPBackfill(context: modelContext)
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
        // Memory Pressure: purge reader image cache to prevent Jetsam kills
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await ReaderImageFilterEngine.shared.purgeCache() }
            Logger.shared.log("⚠️ Memory warning received — purged ReaderImageFilterEngine cache.", category: "Memory", type: .warning)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToLibraryTab"))) { _ in
            selectedTab = 0
        }
        // Hardware Shortcuts
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
                                self.selectedTab = 1 // Switch to Workspace Tab
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
            // Neural Backdrop
            NeuralExpressiveBackground()

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

                // Tab 1: Workspace (Inbox, Convert, Focus Editor)
                WorkspaceView()
                    .tabVisible(selectedTab == 1)

                // Tab 2: Devices & Settings
                DevicesView()
                    .tabVisible(selectedTab == 2)
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
                annotationCount: 0,
                convertingProgress: conversionManager.conversionProgress,
                isConverting: conversionManager.isConverting,
                convertingMessage: conversionManager.processingStatus,
                isImporting: ImportMonitorManager.shared.isImporting,
                importProgress: ImportMonitorManager.shared.progress,
                importMessage: "Importing \(ImportMonitorManager.shared.filesProcessed)/\(ImportMonitorManager.shared.totalFilesToProcess)"
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

    // MARK: - Premium Desktop iPad Layout
    var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                NeuralExpressiveBackground()
                Color.inkBackground.opacity(0.45)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header Label
                    HStack {
                        Text("Inksync Pro")
                            .font(.system(size: 20, weight: .bold, design: .serif))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.primary, .primary.opacity(0.75)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    ScrollView {
                        VStack(spacing: 8) {
                            SidebarRowView(tabIndex: 0, label: "Library", icon: "books.vertical.fill", selectedTab: $selectedTab)
                            SidebarRowView(tabIndex: 1, label: "Workspace", icon: "briefcase.fill", selectedTab: $selectedTab)
                            SidebarRowView(tabIndex: 2, label: "Devices", icon: "ipad.and.iphone", selectedTab: $selectedTab)
                        }
                        .padding(.horizontal, 12)
                    }

                    Spacer()

                    // ── iPad Sidebar Progress Panel ────────────────────────────────
                    iPadProgressPanel

                    SettingsSidebarButton(isPresented: $showingSettingsInspector)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .navigationBarHidden(true)
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
                                _ = ImportQueueManager.shared.stageWithDuplicateCheck(urls)
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
                    WorkspaceView()
                } else if selectedTab == 2 {
                    DevicesView()
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
                    // Header row
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        // Percentage badge
                        Text(progress < 0.01 && progress > 0 ? "<1%" : "\(Int(progress * 100))%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: progress)
                    }

                    // Animated progress track
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
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
            }
        }
    }
}

// MARK: - Custom Sidebar Components
struct SidebarRowView: View {
    let tabIndex: Int
    let label: String
    let icon: String
    @Binding var selectedTab: Int
    @State private var isHovered = false
    
    var body: some View {
        let isSelected = selectedTab == tabIndex
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedTab = tabIndex
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .orange : .inkTextSecondary)
                    .frame(width: 22)
                
                Text(label)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .inkTextPrimary : .inkTextSecondary)
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.inkSurface)
                        
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.inkBorderVisible, lineWidth: 1)
                        
                        // Left accent bar
                        HStack {
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 3, height: 16)
                                .cornerRadius(1.5)
                                .padding(.leading, 1)
                            Spacer()
                        }
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.inkSurface.opacity(0.4))
                    }
                }
            )
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SettingsSidebarButton: View {
    @Binding var isPresented: Bool
    @State private var isHovered = false
    
    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPresented ? "gearshape.fill" : "gear")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isPresented ? .orange : .inkTextSecondary)
                    .frame(width: 22)
                
                Text("Settings")
                    .font(.system(size: 14, weight: isPresented ? .semibold : .medium))
                    .foregroundColor(isPresented ? .inkTextPrimary : .inkTextSecondary)
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    if isPresented {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.inkSurface)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.inkBorderVisible, lineWidth: 1)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.inkSurface.opacity(0.4))
                    }
                }
            )
            .scaleEffect(isHovered && !isPresented ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}




