import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
    // ✅ NEW: Wi-Fi Server for Kindle Sync
    @StateObject private var wifiServer = WiFiServer()
    
    @State private var selectedTab = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
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
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            if sizeClass == .compact {
                liquidGlassLayout
            } else {
                iPadLayout
            }
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
            OnboardingView(showOnboarding: $showOnboarding)
        }
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
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
                }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(0)
            
            // Tab 2: Search (New System Role)
            Text("Global Search")
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(3) // Search is typically 0 or specialized, putting securely at 3
            
            // Tab 3: Work Area
            NavigationStack {
                EditorDashboardView()
            }
            .tabItem { Label("Work Area", systemImage: "pencil.and.outline") }
            .tag(1)
            
            // Tab 4: Settings
            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(2)
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
                Picker("Section", selection: $selectedTab) {
                    Text("Library").tag(0)
                    Text("Work Area").tag(1)
                    Text("Settings").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if selectedTab == 0 {
                    ModernLibraryView(
                        selectedPDF: $selectedPDF,
                        isBatchMode: $isBatchMode,
                        multiSelection: $multiSelection,
                        showingBatchMergeReorder: $showingBatchMergeReorder,
                        batchMergeItems: $batchMergeItems,
                        useNavigationStack: false,
                        onFolderImport: {
                            FolderImportCoordinator.present { urls in
                                guard !urls.isEmpty else { return }
                                Task { await conversionManager.importFilesAsSeries(urls: urls) }
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                } else if selectedTab == 1 {
                    EditorDashboardView()
                } else {
                    SettingsView()
                }
            }
            // Title removed to allow children to define their own or hide it
            // .navigationTitle("Inksync Pro") 
            // .navigationBarTitleDisplayMode(.inline)
            
        } detail: {
            NavigationStack {
                if isBatchMode {
                    BatchSelectionDetailView(
                        selectionCount: multiSelection.count,
                        onConvert: {
                            let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                            Task { await conversionManager.convertQueue(items) }
                            isBatchMode = false
                            multiSelection.removeAll()
                        },
                        onMerge: {
                            batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                            showingBatchMergeReorder = true
                        },
                        onDelete: {
                            let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                            Task {
                                for item in items {
                                    conversionManager.deletePDF(item)
                                }
                            }
                            isBatchMode = false
                            multiSelection.removeAll()
                        },
                        onCancel: {
                            isBatchMode = false
                            multiSelection.removeAll()
                        }
                    )
                } else if let pdf = selectedPDF {
                    ConvertView(pdf: pdf)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: { selectedPDF = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.title3)
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    Button {
                                        Task {
                                            if pdf.fileSize > 50 * 1024 * 1024 {
                                                largeFilePDF = pdf
                                                showingLargeFileAlert = true
                                            } else {
                                                // Generate Metadata-Embedded File before sharing
                                                if let exportURL = await conversionManager.exportForCloudSync(pdf) {
                                                    await MainActor.run {
                                                        let wrapper = ConvertedPDF(id: pdf.id, name: pdf.name, url: exportURL, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata)
                                                        pdfToShare = wrapper
                                                    }
                                                }
                                            }
                                        }
                                    } label: { Label("Export / Share", systemImage: "square.and.arrow.up") }
                                    Button { pdfToEdit = pdf } label: { Label("Edit Pages", systemImage: "doc.on.doc") }
                                    Divider()
                                    Button(role: .destructive) {
                                        conversionManager.deletePDF(pdf)
                                        selectedPDF = nil
                                    } label: { Label("Delete", systemImage: "trash") }
                                } label: {
                                    Image(systemName: "ellipsis.circle").font(.title3)
                                }
                            }
                        }
                        .id(pdf.id)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "book.closed").font(.system(size: 80)).foregroundColor(.gray.opacity(0.3))
                        Text("Select a Comic").font(.title).foregroundColor(.secondary)
                        Text("Select a file from the sidebar or use the buttons below.").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)

    }
}


