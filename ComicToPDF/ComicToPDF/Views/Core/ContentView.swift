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
        .fileExporter(
            isPresented: $showingWebExport,
            document: GenericFileDocument(url: webExportPDF?.url ?? URL(fileURLWithPath: "")),
            contentType: {
                guard let ext = webExportPDF?.url.pathExtension.lowercased() else { return .pdf }
                if ext == "epub" { return .epub }
                if ext == "cbz" { return UTType("com.macitbetter.cbz-archive") ?? .zip }
                if ext == "cbr" { return UTType("com.macitbetter.cbr-archive") ?? .zip }
                if ext == "zip" { return .zip }
                return .pdf
            }(),
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
        .onOpenURL { url in
            // Handle file opening from other apps (AirDrop, Files app)
             Task {
                 await conversionManager.processingStatus = "Importing \(url.lastPathComponent)..."
                 await conversionManager.processImportedFiles(urls: [url])
                 await conversionManager.processingStatus = ""
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
                                        Task {
                                            if pdf.fileSize > 50 * 1024 * 1024 {
                                                largeFilePDF = pdf
                                                showingLargeFileAlert = true
                                            } else {
                                                // Generate Metadata-Embedded File before sharing
                                                if let exportURL = await conversionManager.exportWithEmbeddedMetadata(for: pdf) {
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
        .sheet(isPresented: $showingBatchMergeReorder) {
            BatchMergeReorderView(selectedFiles: $batchMergeItems)
        }

        // ✅ Updated confirmationDialog with Workflow
        .confirmationDialog("Large File Detected", isPresented: $showingLargeFileAlert, titleVisibility: .visible) {
            Button("Save to 'Downloads' & Open Website") {
                // Start Save & Open Flow
                if let pdf = largeFilePDF {
                    Task {
                        // 1. Generate Metadata-Embedded File
                        if let exportURL = await conversionManager.exportWithEmbeddedMetadata(for: pdf) {
                             await MainActor.run {
                                 // We need to pass the URL to the exporter. 
                                 // But GenericFileDocument takes a URL.
                                 // We update the state to point to this new temp file.
                                 // NOTE: We need a way to pass this URL to .fileExporter
                                 // We can just update webExportPDF to be a dummy struct with this URL?
                                 // Or better, add a separate state for 'exportURL' and update GenericFileDocument call.
                                 // For now, let's Mutate the PDF struct in memory to point to the temp URL? 
                                 // No, that's dangerous.
                                 // Let's rely on 'webExportPDF' but we need to change how GenericFileDocument uses it.
                                 // Actually, we can just introduce a specific 'tempExportURL' state.
                                 // But for minimal changes:
                                 var tempPDF = pdf
                                 tempPDF = ConvertedPDF(id: pdf.id, name: pdf.name, url: exportURL, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata) 
                                 webExportPDF = tempPDF
                                 showingWebExport = true
                             }
                        }
                    }
                }
            }
            Button("Share via System Sheet") {
                if let pdf = largeFilePDF {
                    Task {
                        if let exportURL = await conversionManager.exportWithEmbeddedMetadata(for: pdf) {
                            await MainActor.run {
                                // Create a dummy PDF wrapper pointing to temp file for the sheet
                                var tempPDF = pdf
                                // reusing existing init logic to swap URL
                                let wrapper = ConvertedPDF(id: pdf.id, name: pdf.name, url: exportURL, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata)
                                pdfToShare = wrapper
                            }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This file is over 50MB. To upload via browser, save it to 'Downloads' first. We will open the website for you immediately after saving.")
        }
    }
}


