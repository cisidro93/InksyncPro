import SwiftUI
import PDFKit

struct ReaderView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    
    // Reader State
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 0
    @State private var isNightMode: Bool = false
    @State private var showControls: Bool = true
    @State private var isBookmarked: Bool = false
    @State private var scrollMode: ScrollMode = .continuous
    @State private var zoomMode: ZoomMode = .fitWidth
    
    // Sheets
    @State private var showingAppearance = false
    @State private var showingGrid = false
    @State private var showingMetadata = false
    
    enum ScrollMode: String, CaseIterable, Identifiable {
        case single = "Single Page"
        case continuous = "Continuous"
        var id: String { rawValue }
    }
    
    enum ZoomMode: String, CaseIterable, Identifiable {
        case fitPage = "Fit Page"
        case fitWidth = "Fit Width"
        var id: String { rawValue }
    }
    
    var body: some View {
        ZStack {
            // Reader Content
            Color(isNightMode ? .black : .systemBackground).ignoresSafeArea()
            
            if pdf.url.pathExtension.lowercased() == "epub" {
                ComicReaderView(url: pdf.url, currentPage: $currentPage, totalPages: $totalPages, isNightMode: isNightMode, scrollMode: scrollMode, zoomMode: zoomMode)
            } else {
                PDFReaderView(url: pdf.url, currentPage: $currentPage, totalPages: $totalPages, isNightMode: isNightMode, scrollMode: scrollMode, zoomMode: zoomMode)
            }
            
            // Overlays (Night Mode Dimming)
            if isNightMode {
                Color.black.opacity(0.3).ignoresSafeArea().allowsHitTesting(false)
            }
            
            // Controls
            if showControls {
                VStack {
                    topToolbar
                    Spacer()
                    bottomToolbar
                }
                .transition(.opacity)
            }
        }
        .onTapGesture {
            withAnimation { showControls.toggle() }
        }
        .statusBar(hidden: !showControls)
        .onAppear {
            currentPage = pdf.lastReadPage ?? 0
            isNightMode = UserDefaults.standard.bool(forKey: "NightMode")
            checkBookmark()
        }
        .onDisappear {
            // Save progress
            if let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[index].lastReadPage = currentPage
                conversionManager.convertedPDFs[index].readingProgress = Double(currentPage) / Double(max(1, totalPages))
                conversionManager.savePDFs()
            }
        }
        .sheet(isPresented: $showingAppearance) {
            AppearanceSettingsView(isNightMode: $isNightMode, scrollMode: $scrollMode, zoomMode: $zoomMode)
                .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $showingMetadata) {
            MetadataEditorView(pdf: pdf)
                .environmentObject(conversionManager)
        }
        // Grid View for Pages/Bookmarks could be implemented here or separate sheet
    }
    
    var topToolbar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
            }
            Spacer()
            
            Button(action: { 
                 isBookmarked.toggle()
                 toggleBookmark()
            }) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
            }
            
            Button(action: { showingMetadata = true }) {
                Image(systemName: "info.circle")
            }
            
            Button(action: { showingAppearance = true }) {
                Image(systemName: "textformat.size")
            }
        }
        .padding()
        .background(Material.thin)
        .foregroundColor(isNightMode ? .white : .black)
    }
    
    var bottomToolbar: some View {
        VStack {
             if totalPages > 0 {
                 HStack {
                     Text("\(currentPage + 1)/\(totalPages)")
                         .font(.caption)
                         .monospacedDigit()
                 }
                 Slider(value: Binding(get: { Double(currentPage) }, set: { currentPage = Int($0) }), in: 0...Double(max(totalPages - 1, 1)), step: 1)
             }
        }
        .padding()
        .background(Material.thin) // Use thin material for glass effect
        .foregroundColor(isNightMode ? .white : .black)
    }
    
    private func toggleBookmark() {
         guard let index = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) else { return }
         var bookmarks = conversionManager.convertedPDFs[index].bookmarks ?? []
         
         if isBookmarked {
             if !bookmarks.contains(currentPage) { bookmarks.append(currentPage) }
         } else {
             bookmarks.removeAll { $0 == currentPage }
         }
         conversionManager.convertedPDFs[index].bookmarks = bookmarks
         conversionManager.savePDFs()
    }
    
    private func checkBookmark() {
         if let bookmarks = pdf.bookmarks {
             isBookmarked = bookmarks.contains(currentPage)
         }
    }
}

// MARK: - PDF WRAPPER
struct PDFReaderView: UIViewRepresentable {
    let url: URL
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    var isNightMode: Bool
    var scrollMode: ReaderView.ScrollMode
    var zoomMode: ReaderView.ZoomMode
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.backgroundColor = .systemBackground
        if let document = PDFDocument(url: url) {
            pdfView.document = document
            DispatchQueue.main.async {
                totalPages = document.pageCount
            }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        // Sync Page
        if let doc = pdfView.document, doc.pageCount > currentPage {
            let page = doc.page(at: currentPage)
            if let page = page, pdfView.currentPage != page {
                pdfView.go(to: page)
            }
        }
        
        // Sync Mode
        switch scrollMode {
        case .single:
            if pdfView.displayMode != .singlePage {
                pdfView.displayMode = .singlePage
                pdfView.usePageViewController(true)
            }
        case .continuous:
             if pdfView.displayMode != .singlePageContinuous {
                 pdfView.displayMode = .singlePageContinuous
                 pdfView.usePageViewController(false)
             }
        }
        
        // Sync Zoom
        if zoomMode == .fitPage {
            pdfView.autoScales = true // PDFKit handles this logic well with autoScales
        } else {
             // For Fit Width, autoScales often does it too, but we can force scale factor if needed
             // Usually autoScales is Fit Width in continuous mode.
        }
        
        // Night Mode
        pdfView.backgroundColor = isNightMode ? .black : .systemBackground
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject {
        var parent: PDFReaderView
        init(_ parent: PDFReaderView) { self.parent = parent }
        
        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let index = doc.index(for: page)
            DispatchQueue.main.async {
                self.parent.currentPage = index
            }
        }
    }
}

// MARK: - COMIC (EPUB) WRAPPER
struct ComicReaderView: View {
    let url: URL
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    var isNightMode: Bool
    var scrollMode: ReaderView.ScrollMode
    var zoomMode: ReaderView.ZoomMode
    
    @State private var images: [URL] = []
    
    var body: some View {
        Group {
            if images.isEmpty {
                ProgressView("Loading comic...")
            } else {
                if scrollMode == .single {
                    TabView(selection: $currentPage) {
                        ForEach(0..<images.count, id: \.self) { index in
                            AsyncImage(url: images[index]) { phase in
                                switch phase {
                                case .empty: ProgressView()
                                case .success(let image): 
                                     image.resizable()
                                          .aspectRatio(contentMode: zoomMode == .fitPage ? .fit : .fill)
                                case .failure: Image(systemName: "exclamationmark.triangle")
                                @unknown default: EmptyView()
                                }
                            }
                            .tag(index)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(isNightMode ? Color.black : Color.white)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<images.count, id: \.self) { index in
                                    AsyncImage(url: images[index]) { phase in
                                        if let image = phase.image {
                                            image.resizable()
                                                 .aspectRatio(contentMode: .fit) // Continuous usually fits width
                                        } else if phase.error != nil {
                                             Image(systemName: "exclamationmark.triangle").frame(height: 300)
                                        } else {
                                             ProgressView().frame(height: 300)
                                        }
                                    }
                                    .id(index)
                                }
                            }
                        }
                        .onChange(of: currentPage) { newValue in
                            proxy.scrollTo(newValue, anchor: .top)
                        }
                    }
                }
            }
        }
        .task {
            // Load Images
            if images.isEmpty {
                 loadImages()
            }
        }
        .onChange(of: images.count) { count in
            totalPages = count
        }
    }
    
    private func loadImages() {
        Task.detached(priority: .userInitiated) {
            // Use EPUBMerger's extraction logic (we can expose a helper in ConversionManager)
            // Or just use ConversionManager.extractImageURLs
            
            // We need a helper that returns URLs
            do {
                let extracted = try await ConversionManager().extractImageURLs(from: url)
                await MainActor.run {
                    self.images = extracted
                }
            } catch {
                print("Failed to load comic images: \(error)")
            }
        }
    }
}

// MARK: - SETTINGS VIEWS
struct AppearanceSettingsView: View {
    @Binding var isNightMode: Bool
    @Binding var scrollMode: ReaderView.ScrollMode
    @Binding var zoomMode: ReaderView.ZoomMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Display")) {
                    Toggle("Night Mode", isOn: $isNightMode)
                        .onChange(of: isNightMode) { val in
                            UserDefaults.standard.set(val, forKey: "NightMode")
                        }
                }
                
                Section(header: Text("Layout")) {
                    Picker("Scroll Mode", selection: $scrollMode) {
                        ForEach(ReaderView.ScrollMode.allCases) { mode in
                             Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Picker("Zoom", selection: $zoomMode) {
                        ForEach(ReaderView.ZoomMode.allCases) { mode in
                             Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct MetadataEditorView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String = ""
    @State private var author: String = ""
    @State private var series: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Metadata")) {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    TextField("Series", text: $series)
                }
            }
            .navigationTitle("Edit Metadata")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { save(); dismiss() } }
            }
            .onAppear {
                title = pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title
                author = pdf.metadata.author
                series = pdf.metadata.series
            }
        }
    }
    
    private func save() {
         var meta = pdf.metadata
         meta.title = title
         meta.author = author
         meta.series = series
         conversionManager.updatePDFMetadata(pdf, metadata: meta)
    }
}
