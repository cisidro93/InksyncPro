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

// MARK: - Cover Studio
struct CoverStudioView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    // Live reference to ensure UI updates when metadata changes
    var livePDF: ConvertedPDF {
        conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cover Art Studio")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    // 1. ORIGINAL COVER FALLBACK
                    CoverVariantCell(
                        pdf: livePDF,
                        variantID: nil,
                        imageURL: conversionManager.getCoverURL(for: livePDF),
                        isActive: livePDF.metadata.selectedCoverID == nil,
                        onSelect: {
                            Task { await conversionManager.setActiveCoverVariant(nil, for: livePDF) }
                        }
                    )
                    
                    // 2. SAVED VARIANTS
                    ForEach(Array(livePDF.metadata.coverVariants.keys.sorted(by: { $0.uuidString < $1.uuidString })), id: \.self) { variantID in
                        if let url = livePDF.metadata.coverVariants[variantID] {
                            CoverVariantCell(
                                pdf: livePDF,
                                variantID: variantID,
                                imageURL: url,
                                isActive: livePDF.metadata.selectedCoverID == variantID,
                                onSelect: {
                                    Task { await conversionManager.setActiveCoverVariant(variantID, for: livePDF) }
                                }
                            )
                        }
                    }
                    
                    // 3. IMPORT BUTTON
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        VStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                .fill(Color.blue)
                                .frame(width: 160, height: 240)
                                .overlay(
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 40))
                                        .foregroundColor(.blue)
                                )
                            Text("Import Custom")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            
            Divider().padding(.horizontal)
            
            HStack(alignment: .top) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("To extract a cover directly from the comic, press and hold on any page in the Grid and select 'Make Cover Variant'.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
            }
            .padding(.horizontal)
        }
        .padding(.top)
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpegData = image.jpegData(compressionQuality: 0.9) {
                    
                    let variantID = UUID()
                    let fileManager = FileManager.default
                    let coversDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers")
                    try? fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
                    
                    let variantURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
                    try? jpegData.write(to: variantURL)
                    
                    await MainActor.run {
                        if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == livePDF.id }) {
                            conversionManager.convertedPDFs[idx].metadata.coverVariants[variantID] = variantURL
                            conversionManager.saveLibrary()
                        }
                    }
                }
            }
        }
    }
}

// Sub-component for individual cover preview cells
struct CoverVariantCell: View {
    let pdf: ConvertedPDF
    let variantID: UUID?
    let imageURL: URL?
    let isActive: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = imageURL, let uiImage = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.2))
                        }
                    }
                    .frame(width: 160, height: 240)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isActive ? Color.green : Color.clear, lineWidth: 4)
                    )
                    .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)
                    
                    if isActive {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                            .background(Circle().fill(Color.white))
                            .offset(x: 8, y: 8)
                    }
                }
                
                Text(variantID == nil ? "Original" : "Variant")
                    .font(.caption)
                    .fontWeight(isActive ? .bold : .regular)
                    .foregroundColor(isActive ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
