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
    
    // QoL Notification Toast State
    @State private var activeToast: ToastMessage? = nil
    
    @State private var isAppLoading = true
    @State private var isLogoBreathing = false
    @State private var isLogoMorphComplete = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                NeuralExpressiveBackground(isAnimating: selectedPDF == nil)
                
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
                            },
                            isAppLoading: isAppLoading
                        )
                        .navigationDestination(for: ConvertedPDF.self) { pdf in
                            ConvertView(pdf: pdf).id(pdf.id)
                        }
                        .navigationDestination(for: SeriesGroup.self) { group in
                            SeriesDetailView(series: group, selectedPDF: $selectedPDF, useNavigationStack: true)
                                .environmentObject(conversionManager)
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

                    // Tab 3: Notebook / Highlights
                    NavigationStack {
                        GlobalNotebookView(selectedPDF: $selectedPDF)
                            .environmentObject(conversionManager)
                    }
                    .tabVisible(router.selectedTab == 3)
                }
                
                // iPad Progress Panel Overlay
                if sizeClass == .regular {
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
                
                // Premium Skeleton Shimmer Overlay View
                if isAppLoading {
                    AppLoadingScreenView(isAppLoading: $isAppLoading)
                        .zIndex(998)
                        .transition(.opacity)
                }
                
                // Floating brand logo that morphs/slides to top-left navbar
                if !isLogoMorphComplete {
                    let safeAreaTop = geo.safeAreaInsets.top
                    let startPos = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 30)
                    let endPos = CGPoint(x: 34, y: 26) // Aligns with custom unified header space

                    
                    let currentPos = isAppLoading ? startPos : endPos
                    let currentSize = isAppLoading ? CGFloat(130) : CGFloat(32)
                    
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: currentSize, height: currentSize)
                        .clipShape(RoundedRectangle(cornerRadius: currentSize * 0.28))
                        .shadow(color: .black.opacity(isAppLoading ? 0.45 : 0.15), radius: isAppLoading ? 15 : 4, y: isAppLoading ? 8 : 2)
                        .scaleEffect(isAppLoading ? (isLogoBreathing ? 1.04 : 0.98) : 1.0)
                        .position(currentPos)
                        .zIndex(999) // Always on top of all sheets
                        .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !tabBarHidden && !isAppLoading {
                    InkTabBar(
                        selectedTab: $router.selectedTab,
                        isHidden: $tabBarHidden,
                        mode: isBatchMode ? .librarySelection(count: multiSelection.count) : (router.isSeriesSelectionMode ? .seriesSelection(count: router.seriesSelectionCount) : .normal),
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
        .modifier(ToastHUDModifier(activeToast: $activeToast))
        .alert(item: $taskEngine.appAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            LinkedLibraryScanner.shared.conversionManager = conversionManager
            AnnotationStore.shared.initialize(with: modelContext)
            PageModelStore.shared.initialize(with: modelContext)
            
            // Trigger loop for logo breathing animation during load
            if isAppLoading {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isLogoBreathing = true
                }
            }
            
            Task { @MainActor in
                let startTime = Date()
                
                await LibraryDatabaseService.shared.bootstrap()
                
                MigrationService.shared.migrateLegacyDataIfNeeded(context: modelContext)
                MigrationService.shared.migrateLegacyAnnotations(context: modelContext)
                
                // Always fetch the latest SwiftData on startup to ensure conversionManager matches the DB.
                await LibraryService.shared.loadLibrary()
                
                // Run smart grouping asynchronously on background actor context to avoid blocking the Main Actor on launch.
                await LibraryService.shared.runSmartGrouping()
                
                conversionManager.scanLibrary()
                
                await SandboxCleanupManager.shared.passiveScan()
                await SandboxCleanupManager.shared.autoCleanupIfStorageLow()
                
                // Enforce a minimum display duration of 0.5s for smooth animation
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 0.5 {
                    try? await Task.sleep(for: .seconds(0.5 - elapsed))
                }
                
                withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                    isAppLoading = false
                }
                
                Task {
                    try? await Task.sleep(for: .seconds(0.85))
                    withAnimation(.easeOut(duration: 0.25)) {
                        isLogoMorphComplete = true
                    }
                }
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
            Task {
                await ReaderImageFilterEngine.shared.purgeCache()
                await SandboxCleanupManager.shared.autoCleanupIfStorageLow()
            }
            Logger.shared.log("⚠️ Memory warning received — purged ReaderImageFilterEngine cache and verified disk storage limits.", category: "Memory", type: .warning)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Logger.shared.log("App returned to foreground: trigger auto scan for shared container files", category: "Import")
            conversionManager.scanLibrary()
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
        .onOpenURL { url in
            Logger.shared.log("onOpenURL received: \(url.absoluteString)", category: "Import")
            if url.scheme == "inksyncpro" {
                conversionManager.scanLibrary()
                return
            }
            guard url.isFileURL else { return }
            
            let accessing = url.startAccessingSecurityScopedResource()
            Task.detached(priority: .userInitiated) {
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                
                var coordError: NSError?
                var copySuccess = false
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { safeURL in
                    do {
                        try FileManager.default.copyItem(at: safeURL, to: dest)
                        copySuccess = true
                    } catch {
                        Logger.shared.log("onOpenURL: Copy coordinated file failed: \(error.localizedDescription)", category: "Import", type: .error)
                    }
                }
                
                if copySuccess {
                    _ = await ImportQueueManager.shared.stageWithDuplicateCheck([dest])
                    
                    Task { @MainActor in
                        withAnimation(.spring()) {
                            activeToast = ToastMessage(
                                title: "Staged for Import",
                                message: "\(url.lastPathComponent) has been added to import queue.",
                                systemImage: "doc.badge.plus",
                                type: .success
                            )
                        }
                        AppRouter.shared.presentSheet(.importQueue)
                    }
                }
                
                // Perform a complete scan so App Group / shared container files are ingested
                await MainActor.run {
                    conversionManager.scanLibrary()
                }
            }
        }
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

struct ToastHUDView: View {
    let toast: ToastMessage
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(toast.type.color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text(toast.message)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            
            Spacer()
            
            if toast.action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(Color(white: 0.1).opacity(0.95))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
    }
}

struct ToastHUDModifier: ViewModifier {
    @ObservedObject var taskEngine = TaskEngine.shared
    @Binding var activeToast: ToastMessage?
    
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = activeToast {
                    ToastHUDView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture {
                            toast.action?()
                            withAnimation(.spring()) { activeToast = nil }
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                                if activeToast == toast {
                                    withAnimation(.spring()) { activeToast = nil }
                                }
                            }
                        }
                        .padding(.top, 24)
                }
            }
            .onChange(of: taskEngine.statusMessage) { _, newMessage in
                if let msg = newMessage {
                    if msg.starts(with: "✅") {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        
                        let sortedItems = LibraryService.shared.items.sorted { $0.lastModified > $1.lastModified }
                        let latestBook = sortedItems.first
                        
                        withAnimation(.spring()) {
                            activeToast = ToastMessage(
                                title: "Complete",
                                message: msg.replacingOccurrences(of: "✅ ", with: ""),
                                systemImage: "checkmark.circle.fill",
                                type: .success,
                                action: {
                                    if let book = latestBook {
                                        NotificationCenter.default.post(name: .openMergedBook, object: book)
                                    }
                                }
                            )
                        }
                    } else if msg.starts(with: "Error") || msg.starts(with: "Merge Error") {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.error)
                        
                        withAnimation(.spring()) {
                            activeToast = ToastMessage(
                                title: "Failed",
                                message: msg,
                                systemImage: "exclamationmark.triangle.fill",
                                type: .warning
                            )
                        }
                    }
                }
            }
            .onChange(of: taskEngine.appAlert) { _, newAlert in
                if let alert = newAlert {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.warning)
                    
                    withAnimation(.spring()) {
                        activeToast = ToastMessage(
                            title: alert.title,
                            message: alert.message,
                            systemImage: "exclamationmark.triangle.fill",
                            type: .warning
                        )
                    }
                    taskEngine.appAlert = nil
                }
            }
    }
}




