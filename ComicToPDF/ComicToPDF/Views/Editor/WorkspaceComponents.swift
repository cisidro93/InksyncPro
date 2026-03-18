import SwiftUI
import PhotosUI

// MARK: - Canvas View
struct WorkspaceCanvasView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    @ObservedObject var viewModel: PageEditorViewModel
    @Binding var selectedPages: Set<Int>
    
    @State private var pageToEdit: Int?
    @State private var draggedItem: GridPageItem?
    
    // Scale features
    @State private var gridColumns: Int = 3
    @GestureState private var pinchMagnification: CGFloat = 1.0
    @State private var baseColumns: Int = 3
    
    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, gridColumns))
    }
    
    var body: some View {
        ZStack {
            if let error = viewModel.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text("Error").font(.headline)
                    Text(error).font(.caption)
                }
            } else if viewModel.isLoading {
                ProgressView("Loading Workspace...")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(viewModel.items) { item in
                            PageManagerGridItem(
                                item: item,
                                pdf: pdf,
                                isSelectionMode: true, // Always allow selection
                                isSelected: selectedPages.contains(item.index),
                                items: $viewModel.items,
                                draggedItem: $draggedItem,
                                onToggleSelection: { toggleSelection(item.index) },
                                onEdit: { _ in
                                    self.pageToEdit = item.index
                                    selectedPages.removeAll() // Clear selection on enter
                                }
                            )
                            // Context Menu for Advanced Canvas Operations
                            .contextMenu {
                                Button {
                                    Task {
                                        do {
                                            try await conversionManager.extractCoverVariant(from: pdf, pageIndex: item.index)
                                            // Optionally, switch to the Cover Studio tab to show off the new variant
                                        } catch {
                                            print("Cover Extraction Error: \(error)")
                                        }
                                    }
                                } label: { Label("Make Cover Variant", systemImage: "photo.badge.plus") }
                                
                                Button {
                                    self.pageToEdit = item.index
                                } label: { Label("Precision Tools", systemImage: "paintbrush.pointed") }
                                
                                Divider()
                                
                                Button(role: .destructive) {
                                } label: { Label("Delete Page", systemImage: "trash") }
                            }
                        }
                    }
                    .padding()
                    .padding(.bottom, 100) // Space for floating palette
                }
                // Pinch to Zoom Grid Gesture
                .gesture(
                    MagnifyGesture()
                        .updating($pinchMagnification) { value, state, _ in
                            state = value.magnification
                        }
                        .onEnded { value in
                            let target = baseColumns - Int(round(value.magnification - 1))
                            baseColumns = max(1, min(7, target))
                            withAnimation(.spring) { gridColumns = baseColumns }
                        }
                )
                .onChange(of: pinchMagnification) { _, newValue in
                    let target = baseColumns - Int(round(newValue - 1))
                    let newCols = max(1, min(7, target))
                    if newCols != gridColumns {
                        withAnimation(.interactiveSpring) { gridColumns = newCols }
                    }
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { pageToEdit != nil },
            set: { if !$0 { pageToEdit = nil } }
        )) {
            if let index = pageToEdit {
                PrecisionCanvasView(
                    pdf: pdf,
                    pageIndex: Binding(get: { index }, set: { pageToEdit = $0 }),
                    totalCount: viewModel.items.count,
                    conversionManager: conversionManager
                )
            }
        }
    }
    
    func toggleSelection(_ index: Int) {
        if selectedPages.contains(index) { selectedPages.remove(index) }
        else { selectedPages.insert(index) }
    }
}

// MARK: - Floating Tool Palette
struct WorkspaceToolPalette: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    @ObservedObject var viewModel: PageEditorViewModel
    @Binding var selectedPages: Set<Int>
    
    var body: some View {
        HStack(spacing: 20) {
            if selectedPages.isEmpty {
                // Empty State Palette
                Button(action: {
                    selectedPages = Set(viewModel.items.map { $0.index })
                }) {
                    Label("Select All", systemImage: "checkmark.circle.fill")
                }
                
                Divider().frame(height: 20)
                
                Button(action: {
                    // Sorting logic
                }) {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                
            } else if selectedPages.count == 1 {
                // Single Selection Palette
                let index = selectedPages.first!
                
                Button(action: {
                    // Navigate strictly through AdvancedWorkspaceView binding. 
                    // To do this properly, we'd need pageToEdit bound up from Canvas.
                    // For now, let's keep it simple or hook it into a notification.
                    // Given the constraint, we will rely on internal logic.
                }) {
                    Label("Precision Tools", systemImage: "paintbrush.pointed")
                }
                
                Divider().frame(height: 20)
                
                Button(action: {
                    Task {
                        try? await conversionManager.extractCoverVariant(from: pdf, pageIndex: index)
                    }
                }) {
                    Label("Set Cover", systemImage: "photo.badge.plus")
                }
                
                Divider().frame(height: 20)
                
                Button(role: .destructive, action: {
                    Task { await deleteSelected() }
                }) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                
            } else {
                // Multi-Selection Palette
                Text("\(selectedPages.count) Selected").bold()
                
                Divider().frame(height: 20)
                
                if pdf.contentType != .book {
                    Button(action: {
                        Task { await extractSelected() }
                    }) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                }
                
                Button(role: .destructive, action: {
                    Task { await deleteSelected() }
                }) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 10, y: 5)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedPages.count)
    }
    
    // Actions ported from PageManagerView
    func deleteSelected() async {
        guard !selectedPages.isEmpty else { return }
        viewModel.isLoading = true
        viewModel.statusText = "Deleting \(selectedPages.count) pages..."
        
        do {
            try await conversionManager.deletePages(from: pdf, pageIndices: selectedPages)
            selectedPages.removeAll()
            viewModel.cleanup()
            await viewModel.loadPages(from: pdf)
        } catch {
             viewModel.errorMessage = "Delete failed: \(error.localizedDescription)"
             viewModel.isLoading = false
        }
    }
    
    func extractSelected() async {
        guard !selectedPages.isEmpty else { return }
        viewModel.isLoading = true
        viewModel.statusText = "Extracting \(selectedPages.count) pages..."
        
        do {
             let sortedIndices = selectedPages.sorted()
             let _ = try await conversionManager.extractPages(from: pdf, pageIndices: sortedIndices, asImages: true)
             try? await Task.sleep(nanoseconds: 1_000_000_000)
             selectedPages.removeAll()
             viewModel.isLoading = false
        } catch {
             viewModel.errorMessage = "Split failed: \(error.localizedDescription)"
             viewModel.isLoading = false
        }
    }
}

// MARK: - Inspector View
struct WorkspaceInspectorView: View {
    let pdf: ConvertedPDF
    @Binding var activeTab: AdvancedWorkspaceView.WorkspaceTab
    
    var body: some View {
        VStack(spacing: 0) {
            // Inspector Segments
            Picker("Inspector", selection: $activeTab) {
                Text("Metadata").tag(AdvancedWorkspaceView.WorkspaceTab.metadata)
                if pdf.contentType == .book {
                    Text("Chapters").tag(AdvancedWorkspaceView.WorkspaceTab.chapters)
                }
                Text("Covers").tag(AdvancedWorkspaceView.WorkspaceTab.coverStudio)
            }
            .pickerStyle(.segmented)
            .padding()
            
            ScrollView {
                switch activeTab {
                case .metadata:
                    MetadataSearchSheet(pdf: pdf) // Reusing existing component conceptually. Will need adjusting for non-modal context
                case .chapters:
                    Text("Chapter List View")
                case .coverStudio:
                    CoverStudioView(pdf: pdf)
                default:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Cover Studio (The "Cover House")
struct CoverStudioView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    // Live reference to ensure UI updates when metadata changes
    var livePDF: ConvertedPDF {
        conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf
    }
    
    // Cover House Advanced State
    @State private var previewCoverURL: URL? = nil // The Live Preview Main Stage
    @State private var fetchedCovers: [FetchedCover] = []
    @State private var isFetching = false
    @State private var hasFetched = false
    @State private var fetchLimit = 10

    
    var activeCoverURL: URL? { conversionManager.getCoverURL(for: livePDF) }
    
    private var displayImage: UIImage? {
        guard let url = previewCoverURL ?? activeCoverURL else { return nil }
        if url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        } else {
            if let data = try? Data(contentsOf: url) {
                return UIImage(data: data)
            }
        }
        return nil
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Cover House")
                .font(.title2)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            
            mainStageView
            
            galleryView
        }
    }
    
    // --- THE MAIN STAGE (LIVE PREVIEW) ---
    private var mainStageView: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .frame(height: 380)
                .shadow(radius: 10, y: 5)
            
            if let displayURL = previewCoverURL ?? activeCoverURL, let uiImage = displayImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 360)
                    .cornerRadius(12)
                    .padding(10)
            } else {
                VStack {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("No Cover Selected")
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Apply Button (Only if previewing a different cover)
            if previewCoverURL != nil && previewCoverURL != activeCoverURL {
                Button(action: {
                    Task { await applyPreviewCover() }
                }) {
                    Label("Apply Cover", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(radius: 5)
                }
                .padding()
            }
        }
        .padding(.horizontal)
    }

    // --- THE UNIFIED GALLERY ---
    private var galleryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Variants & Recommendations")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    
                    // 1. ORIGINAL COVER FALLBACK
                    CoverVariantCell(
                        imageURL: conversionManager.getOriginalCoverURL(for: livePDF),
                        label: "Original",
                        isActive: activeCoverURL == conversionManager.getOriginalCoverURL(for: livePDF),
                        onSelect: { previewCoverURL = conversionManager.getOriginalCoverURL(for: livePDF) }
                    )
                    
                    // 2. SAVED VARIANTS (From User Extraction / Previous applying)
                    ForEach(Array(livePDF.metadata.coverVariants.keys.sorted(by: { $0.uuidString < $1.uuidString })), id: \.self) { variantID in
                        if let url = livePDF.metadata.coverVariants[variantID] {
                            CoverVariantCell(
                                imageURL: url,
                                label: "Saved Variant",
                                isActive: activeCoverURL == url,
                                onSelect: { previewCoverURL = url }
                            )
                        }
                    }
                    
                    // 3. FETCHED TOP 10 RECOMMENDATIONS
                    ForEach(fetchedCovers) { fetched in
                        CoverVariantCell(
                            imageURL: fetched.url,
                            label: fetched.sourceName,
                            isActive: activeCoverURL == fetched.url,
                            isAI: fetched.isAIHunted,
                            onSelect: { previewCoverURL = fetched.url }
                        )
                    }
                    
                    // 4. FETCH ACTION / LOAD MORE
                    if isFetching {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Hunting...").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(width: 140, height: 210)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    } else {
                        Button(action: fetchCoverRecommendations) {
                            VStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                    .fill(Color.orange)
                                    .frame(width: 140, height: 210)
                                    .overlay(
                                        VStack {
                                            Image(systemName: "magnifyingglass.circle.fill")
                                                .font(.system(size: 40))
                                                .foregroundColor(.orange)
                                            Text(hasFetched ? "Load More" : "Find Covers")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.orange)
                                                .padding(.top, 4)
                                        }
                                    )
                            }
                        }
                    }
                    
                    // 5. IMPORT BUTTON
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        VStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                .fill(Color.blue)
                                .frame(width: 140, height: 210)
                                .overlay(
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 40))
                                        .foregroundColor(.blue)
                                )
                            Text("Library")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                        }
                    }
                    
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .padding(.top)
        .onAppear {
            if !hasFetched && fetchedCovers.isEmpty {
                // Auto-fetch on initial load for premium feel
                fetchCoverRecommendations()
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpegData = image.jpegData(compressionQuality: 0.9) {
                    
                    let variantID = UUID()
                    let coversDir = ConversionManager.getCoversDirectory()
                    let variantURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
                    try? jpegData.write(to: variantURL)
                    
                    await MainActor.run {
                        if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == livePDF.id }) {
                            conversionManager.convertedPDFs[idx].metadata.coverVariants[variantID] = variantURL
                            conversionManager.saveLibrary()
                            previewCoverURL = variantURL
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Cover Fetching Logic
    private func fetchCoverRecommendations() {
        guard !isFetching else { return }
        isFetching = true
        
        Task {
            // Check for BYOK AI Key
            let aiKey = conversionManager.conversionSettings.openAIAPIKey
            
            let results = await CoverFetchService.shared.fetchCovers(for: livePDF.metadata, openAIKey: aiKey.isEmpty ? nil : aiKey, limit: fetchLimit)

            
            await MainActor.run {
                if !hasFetched {
                    self.fetchedCovers = results
                } else {
                    // Load More: Append new unique ones
                    for res in results where !self.fetchedCovers.contains(where: { $0.url == res.url }) {
                        self.fetchedCovers.append(res)
                    }
                }
                self.hasFetched = true
                self.isFetching = false
                if self.hasFetched {
                    self.fetchLimit += 10 // increment for the next "Load More"
                }
            }
        }
    }
    
    private func applyPreviewCover() async {
        guard let targetURL = previewCoverURL else { return }
        
        // If it's an online URL, we must download and save it to the local app sandbox variant bucket
        if !targetURL.isFileURL {
            // Download Data
            if let (data, _) = try? await URLSession.shared.data(from: targetURL),
               let image = UIImage(data: data),
               let jpegData = image.jpegData(compressionQuality: 0.9) {
                
                let variantID = UUID()
                let coversDir = ConversionManager.getCoversDirectory()
                let finalLocalURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
                try? jpegData.write(to: finalLocalURL)
                
                // Update Metadata & Make Active
                await MainActor.run {
                    if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == livePDF.id }) {
                        conversionManager.convertedPDFs[idx].metadata.coverVariants[variantID] = finalLocalURL
                        Task { await conversionManager.setActiveCoverVariant(variantID, for: livePDF) }
                        previewCoverURL = finalLocalURL // Update preview reference
                    }
                }
            }
        } else {
            // It's already local (Original or Saved Variant)
            // Just apply it via ConversionManager
            let variantID = livePDF.metadata.coverVariants.first(where: { $0.value == targetURL })?.key
            await conversionManager.setActiveCoverVariant(variantID, for: livePDF)
        }
    }
}

// Sub-component for individual cover preview cells
struct CoverVariantCell: View {
    let imageURL: URL?
    let label: String
    let isActive: Bool
    var isAI: Bool = false
    let onSelect: () -> Void
    
    @State private var webImage: UIImage? = nil
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = imageURL {
                            if url.isFileURL {
                                if let uiImage = UIImage(contentsOfFile: url.path) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(Color.gray.opacity(0.2))
                                }
                            } else {
                                // Async Web Image Loading
                                if let img = webImage {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .onAppear {
                                            loadWebImage(from: url)
                                        }
                                }
                            }
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.1))
                        }
                    }
                    .frame(width: 140, height: 210)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isActive ? Color.blue : Color.clear, lineWidth: 4)
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 5, y: 3)
                    
                    if isAI {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundColor(.purple)
                            .padding(6)
                            .background(Circle().fill(Color.white))
                            .offset(x: 4, y: 4)
                    } else if isActive {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .background(Circle().fill(Color.white))
                            .offset(x: 4, y: 4)
                    }
                }
                
                Text(label)
                    .font(.caption2)
                    .fontWeight(isActive ? .bold : .medium)
                    .foregroundColor(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: 130)
            }
        }
        .buttonStyle(.plain)
    }
    
    // Lightweight async loader for web thumbnails
    private func loadWebImage(from url: URL) {
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) {
                await MainActor.run { self.webImage = img }
            }
        }
    }
}
