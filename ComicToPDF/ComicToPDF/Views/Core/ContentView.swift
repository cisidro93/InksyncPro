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
    // ✅ Onboarding State
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                iPhoneLayout
            } else {
                iPadLayout
            }
        }
        .environmentObject(conversionManager)
        .environmentObject(wifiServer)
        // ✅ NEW: Apply Dynamic Text Size Globally
        .environment(\.dynamicTypeSize, conversionManager.conversionSettings.textSize.swiftUIValue)
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
    .sheet(isPresented: $showOnboarding) {
        OnboardingView(showOnboarding: $showOnboarding)
            .environmentObject(conversionManager)
    }
    .onAppear {
        if !hasCompletedOnboarding {
            showOnboarding = true
        }
    }
    .sheet(isPresented: $showingBatchMergeReorder) {
        BatchMergeReorderView(selectedFiles: $batchMergeItems)
    }
    .confirmationDialog("Large File Detected", isPresented: $showingLargeFileAlert, titleVisibility: .visible) {
        Button("Save to 'Downloads' & Open Website") {
            if let pdf = largeFilePDF {
                Task {
                    if let exportURL = await conversionManager.exportForCloudSync(pdf) {
                         await MainActor.run {
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
                    if let exportURL = await conversionManager.exportForCloudSync(pdf) {
                        await MainActor.run {
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
    .alert(item: $conversionManager.appAlert) { alert in
        Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
    }
    .overlay(alignment: .bottom) {
        if !conversionManager.processingStatus.isEmpty {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text(conversionManager.processingStatus)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 28/255, green: 28/255, blue: 30/255))
            .cornerRadius(30)
            .shadow(radius: 10)
            .padding(.bottom, 60) // Lift above tab bar if present
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(), value: conversionManager.processingStatus)
        }
    }
}
    
    var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            // ✅ Modern Library with Batch Support
            NavigationStack {
                ZStack(alignment: .bottom) {
                    ModernLibraryView(
                        selectedPDF: $selectedPDF,
                        isBatchMode: $isBatchMode,
                        multiSelection: $multiSelection,
                        showingBatchMergeReorder: $showingBatchMergeReorder,
                        batchMergeItems: $batchMergeItems,
                        useNavigationStack: true
                    )
                    // Hide Native Bar to use ModernLibraryView's custom header
                    .toolbar(.hidden, for: .navigationBar) 
                    
                    // Batch Actions Bottom Bar
                    if isBatchMode {
                        VStack(spacing: 0) {
                            Divider()
                            HStack(spacing: 20) {
                                Button(action: {
                                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    Task {
                                        await conversionManager.convertQueue(items)
                                        isBatchMode = false
                                        multiSelection.removeAll()
                                        selectedTab = 1 // Go to Work Area
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text("Convert")
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .disabled(multiSelection.isEmpty)
                                
                                Button(action: {
                                    batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    showingBatchMergeReorder = true
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc.fill")
                                        Text("Merge")
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .disabled(multiSelection.count < 2)
                                
                                Button(role: .destructive, action: {
                                    let items = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                    Task {
                                        for item in items {
                                            conversionManager.deletePDF(item)
                                        }
                                        isBatchMode = false
                                        multiSelection.removeAll()
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "trash")
                                        Text("Delete")
                                            .font(.caption)
                                    }
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity)
                                }
                                .disabled(multiSelection.isEmpty)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .background(Color(UIColor.systemBackground))
                        }
                        .transition(.move(edge: .bottom))
                    }
                }
                .navigationDestination(for: ConvertedPDF.self) { pdf in
                    ConvertView(pdf: pdf)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    Button {
                                        Task {
                                            if pdf.fileSize > 50 * 1024 * 1024 {
                                                largeFilePDF = pdf
                                                showingLargeFileAlert = true
                                            } else {
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
                                        // Pop back logic handled by NavigationStack state if bound, but here just delete
                                    } label: { Label("Delete", systemImage: "trash") }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                        }
                }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }.tag(0)

            NavigationStack {
                EditorDashboardView()
            }
            .tabItem { Label("Work Area", systemImage: "pencil.and.outline") }.tag(1)
            
            NavigationStack {
                SettingsView()
            }
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
                        batchMergeItems: $batchMergeItems,
                        useNavigationStack: false
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


