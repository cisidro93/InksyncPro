import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var conversionManager = ConversionManager()
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
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                iPhoneLayout
            } else {
                iPadLayout
            }
        }
        .environmentObject(conversionManager)
        // ✅ NEW: Apply Dynamic Text Size Globally
        .environment(\.dynamicTypeSize, conversionManager.conversionSettings.textSize.swiftUIValue)
        // ✅ Show Onboarding on First Launch
        .fullScreenCover(isPresented: Binding(
            get: { !hasShownOnboarding },
            set: { hasShownOnboarding = !$0 }
        )) {
            OnboardingView()
        }
        .sheet(item: $pdfToShare) { pdf in ShareSheet(activityItems: [pdf.url]) }
        .sheet(item: $pdfToEdit) { pdf in 
            PageManagerView(pdf: pdf)
                .environmentObject(conversionManager)
        }
        // ✅ "Save for Web" File Exporter (Global)
        .fileExporter(
            isPresented: $showingWebExport,
            document: GenericFileDocument(url: webExportPDF?.url ?? URL(fileURLWithPath: "")),
            contentType: (webExportPDF?.url.pathExtension.lowercased() == "epub") ? .epub : .pdf,
            defaultFilename: webExportPDF?.name ?? "Comic"
        ) { result in
            switch result {
            case .success:
                // Automatically open Safari after saving
                if let url = URL(string: "https://www.amazon.com/gp/sendtokindle") {
                    UIApplication.shared.open(url)
                }
            case .failure(let error):
                print("Export failed: \(error.localizedDescription)")
            }
        }
    }
    
    var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            LibraryView(selectedTab: $selectedTab)
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(0)
            EditorDashboardView()
                .tabItem { Label("Work Area", systemImage: "pencil.and.outline") }.tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }.tag(2)
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
                        batchMergeItems: $batchMergeItems
                    )
                } else if selectedTab == 1 {
                    EditorDashboardView()
                } else {
                    SettingsView()
                }
            }
            .navigationTitle("Inksync Pro")
            .navigationBarTitleDisplayMode(.inline)
            
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
                                        if pdf.fileSize > 100 * 1024 * 1024 {
                                            largeFilePDF = pdf
                                            showingLargeFileAlert = true
                                        } else {
                                            pdfToShare = pdf
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
        .sheet(isPresented: $showingBatchMergeReorder) {
            BatchMergeReorderView(selectedFiles: $batchMergeItems)
        }

        // ✅ Updated confirmationDialog with Workflow
        .confirmationDialog("Large File Detected", isPresented: $showingLargeFileAlert, titleVisibility: .visible) {
            Button("Save to 'Downloads' & Open Website") {
                // Start Save & Open Flow
                if let pdf = largeFilePDF {
                    webExportPDF = pdf
                    showingWebExport = true 
                }
            }
            Button("Share via System Sheet") {
                if let pdf = largeFilePDF {
                    pdfToShare = pdf
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This file is over 100MB. To upload via browser, save it to 'Downloads' first. We will open the website for you immediately after saving.")
        }
    }
}


