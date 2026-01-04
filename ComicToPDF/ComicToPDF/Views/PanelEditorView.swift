import SwiftUI

struct PanelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: PanelEditorViewModel
    
    // State for drawing new panels
    @State private var isDrawing = false
    @State private var newPanelStart: CGPoint?
    @State private var newPanelCurrent: CGPoint?
    
    init(session: PanelEditSession, onComplete: @escaping (PanelEditSession) -> Void) {
        _viewModel = StateObject(wrappedValue: PanelEditorViewModel(session: session, onComplete: onComplete))
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // Top controls
                HStack {
                    Button(action: { viewModel.autoDetectCurrentPage() }) {
                        Label("Auto-Detect", systemImage: "wand.and.stars")
                    }
                    Spacer()
                    Toggle("Draw Mode", isOn: $isDrawing)
                        .toggleStyle(.button)
                        .tint(.orange)
                    Spacer()
                    Button(action: { viewModel.clearCurrentPage() }) {
                        Label("Clear All", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .padding()
                
                // Main Content
                if let page = viewModel.currentPage, let loadedImage = viewModel.currentLoadedImage {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            // Left: Image Canvas
                            ZStack(alignment: .topLeading) {
                                Color.black.opacity(0.1)
                                
                                // 1. Base Image
                                Image(uiImage: loadedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .overlay(
                                        GeometryReader { imageGeo in
                                            ZStack(alignment: .topLeading) {
                                                // 2. Existing Panels Overlay
                                                PanelOverlay(
                                                    panels: page.panels,
                                                    selectedID: viewModel.selectedPanelID,
                                                    imageSize: loadedImage.size,
                                                    viewSize: imageGeo.size,
                                                    onSelect: { id in
                                                        if !isDrawing { viewModel.selectedPanelID = id }
                                                    },
                                                    onUpdate: { id, newRect in
                                                        viewModel.updatePanelRect(id: id, newRect: newRect)
                                                    }
                                                )
                                                
                                                // 3. Drawing New Panel Overlay
                                                if isDrawing {
                                                    DrawingOverlay(start: newPanelStart, current: newPanelCurrent)
                                                }
                                                
                                                // 4. Drawing Gesture Layer
                                                if isDrawing {
                                                    Color.white.opacity(0.001)
                                                        .gesture(
                                                            DragGesture(minimumDistance: 0)
                                                                .onChanged { value in
                                                                    if newPanelStart == nil { newPanelStart = value.location }
                                                                    newPanelCurrent = value.location
                                                                }
                                                                .onEnded { value in
                                                                    guard let start = newPanelStart else { return }
                                                                    let end = value.location
                                                                    let rect = CGRect(x: min(start.x, end.x),
                                                                                      y: min(start.y, end.y),
                                                                                      width: abs(end.x - start.x),
                                                                                      height: abs(end.y - start.y))
                                                                    
                                                                    if rect.width > 20 && rect.height > 20 {
                                                                        // Convert View Rect to Image Rect
                                                                        let viewSize = imageGeo.size
                                                                        let imageSize = loadedImage.size
                                                                        let scaleX = imageSize.width / viewSize.width
                                                                        let scaleY = imageSize.height / viewSize.height
                                                                        
                                                                        let imageRect = CGRect(
                                                                            x: rect.origin.x * scaleX, // Simplified scale mapping
                                                                            y: rect.origin.y * scaleY,
                                                                            width: rect.width * scaleX,
                                                                            height: rect.height * scaleY
                                                                        )
                                                                        // Use simpler aspect fit scale logic if needed, 
                                                                        // but direct scaling matches overlay logic best.
                                                                        viewModel.addPanel(rect: imageRect)
                                                                    }
                                                                    newPanelStart = nil
                                                                    newPanelCurrent = nil
                                                                }
                                                        )
                                                }
                                            }
                                        }
                                    )
                            }
                            .frame(maxWidth: .infinity)
                            .clipped()
                            
                            // Right: Panel List
                            VStack {
                                Text("Panels: \(page.panels.count)")
                                    .font(.headline)
                                    .padding(.top)
                                    .onTapGesture { viewModel.selectedPanelID = nil }
                                
                                List {
                                    ForEach(page.panels) { panel in
                                        HStack {
                                            Text("Panel \(panel.order)")
                                                .fontWeight(panel.id == viewModel.selectedPanelID ? .bold : .regular)
                                            Spacer()
                                            if panel.id == viewModel.selectedPanelID {
                                                Image(systemName: "checkmark").foregroundColor(.blue)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.selectedPanelID = panel.id
                                            isDrawing = false
                                        }
                                    }
                                    .onDelete { viewModel.deletePanels(at: $0) }
                                    .onMove { viewModel.movePanels(from: $0, to: $1) }
                                }
                                .listStyle(.plain)
                                
                                if viewModel.selectedPanelID != nil {
                                    Button("Delete Selected") {
                                        viewModel.deleteSelectedPanel()
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .padding()
                                }
                            }
                            .frame(width: 250)
                            .background(Color(UIColor.secondarySystemBackground))
                        }
                    }
                } else {
                    VStack {
                        ProgressView()
                        Text("Loading Page...")
                    }
                }
                
                // Bottom Navigation
                HStack {
                    Button("Previous Page") { viewModel.previousPage() }
                        .disabled(viewModel.session.currentPageIndex == 0)
                    Spacer()
                    Text("Page \(viewModel.session.currentPageIndex + 1) of \(viewModel.session.pages.count)")
                    Spacer()
                    Button("Next Page") { viewModel.nextPage() }
                        .disabled(viewModel.session.currentPageIndex == viewModel.session.pages.count - 1)
                }
                .padding()
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("Panel Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        viewModel.saveAndComplete()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            viewModel.loadImage()
        }
    }
}

// MARK: - Helper Views & ViewModel

struct DrawingOverlay: View {
    let start: CGPoint?
    let current: CGPoint?
    var body: some View {
        if let s = start, let c = current {
            Path { path in
                let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                                  width: abs(c.x - s.x), height: abs(c.y - s.y))
                path.addRect(rect)
            }
            .stroke(Color.green, lineWidth: 2)
        }
    }
}

struct PanelOverlay: View {
    let panels: [EditablePanel]
    let selectedID: UUID?
    let imageSize: CGSize
    let viewSize: CGSize
    let onSelect: (UUID) -> Void
    let onUpdate: (UUID, CGRect) -> Void
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(panels) { panel in
                let viewRect = convertToViewRect(panel.rect)
                let isSelected = panel.id == selectedID
                
                ZStack {
                    Rectangle()
                        .stroke(isSelected ? Color.blue : Color.yellow, lineWidth: isSelected ? 3 : 2)
                        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if isSelected {
                                        let newOrigin = CGPoint(x: viewRect.origin.x + value.translation.width,
                                                                y: viewRect.origin.y + value.translation.height)
                                        let newRect = CGRect(origin: newOrigin, size: viewRect.size)
                                        onUpdate(panel.id, convertToImageRect(newRect))
                                    }
                                }
                        )
                        .onTapGesture { onSelect(panel.id) }
                    
                    Text("\(panel.order)")
                        .font(.caption).bold()
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                        .foregroundColor(.white)
                        .position(x: 20, y: 20)
                        .allowsHitTesting(false)
                    
                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 20, height: 20)
                            .position(x: viewRect.width, y: viewRect.height)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let newWidth = max(20, viewRect.width + value.translation.width)
                                        let newHeight = max(20, viewRect.height + value.translation.height)
                                        let newRect = CGRect(x: viewRect.origin.x, y: viewRect.origin.y, width: newWidth, height: newHeight)
                                        onUpdate(panel.id, convertToImageRect(newRect))
                                    }
                            )
                    }
                }
                .frame(width: viewRect.width, height: viewRect.height)
                .position(x: viewRect.midX, y: viewRect.midY)
            }
        }
    }
    
    func convertToViewRect(_ imageRect: CGRect) -> CGRect {
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        
        return CGRect(
            x: imageRect.origin.x * scaleX,
            y: imageRect.origin.y * scaleY,
            width: imageRect.width * scaleX,
            height: imageRect.height * scaleY
        )
    }
    
    func convertToImageRect(_ viewRect: CGRect) -> CGRect {
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        
        return CGRect(
            x: viewRect.origin.x / scaleX,
            y: viewRect.origin.y / scaleY,
            width: viewRect.width / scaleX,
            height: viewRect.height / scaleY
        )
    }
}

class PanelEditorViewModel: ObservableObject {
    @Published var session: PanelEditSession
    @Published var selectedPanelID: UUID?
    @Published var currentLoadedImage: UIImage?
    let onComplete: (PanelEditSession) -> Void
    
    init(session: PanelEditSession, onComplete: @escaping (PanelEditSession) -> Void) {
        self.session = session
        self.onComplete = onComplete
    }
    
    var currentPage: PanelEditSession.PageEditData? {
        guard session.currentPageIndex < session.pages.count else { return nil }
        return session.pages[session.currentPageIndex]
    }
    
    // MEMORY FIX: Load image on demand
    func loadImage() {
        guard let page = currentPage else { return }
        if let current = currentLoadedImage, current.accessibilityIdentifier == page.imageURL.path {
             return 
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = try? Data(contentsOf: page.imageURL), let image = UIImage(data: data) {
                image.accessibilityIdentifier = page.imageURL.path
                DispatchQueue.main.async {
                    self.currentLoadedImage = image
                }
            }
        }
    }
    
    func updatePanelRect(id: UUID, newRect: CGRect) {
        guard var page = currentPage, let index = page.panels.firstIndex(where: { $0.id == id }) else { return }
        page.panels[index].rect = newRect
        updatePage(page)
    }
    
    func addPanel(rect: CGRect) {
        guard var page = currentPage else { return }
        let newOrder = page.panels.count + 1
        let panel = EditablePanel(rect: rect, order: newOrder)
        page.panels.append(panel)
        updatePage(page)
        selectedPanelID = panel.id
    }
    
    func autoDetectCurrentPage() {
        guard let page = currentPage, let image = currentLoadedImage else { return }
        Task {
            let panels = try? await PanelExtractor.extractPanels(from: image, mode: .automatic)
            await MainActor.run {
                var updatedPage = page
                updatedPage.panels = (panels ?? []).enumerated().map { EditablePanel(from: $0.element, order: $0.offset + 1) }
                updatePage(updatedPage)
            }
        }
    }
    
    func clearCurrentPage() {
        guard var page = currentPage else { return }
        page.panels.removeAll()
        updatePage(page)
    }
    
    func deleteSelectedPanel() {
        guard var page = currentPage, let id = selectedPanelID else { return }
        page.panels.removeAll { $0.id == id }
        updatePage(page)
        selectedPanelID = nil
    }
    
    func deletePanels(at offsets: IndexSet) {
        guard var page = currentPage else { return }
        page.panels.remove(atOffsets: offsets)
        updatePage(page)
    }
    
    func movePanels(from source: IndexSet, to destination: Int) {
        guard var page = currentPage else { return }
        page.panels.move(fromOffsets: source, toOffset: destination)
        for (index, _) in page.panels.enumerated() {
            page.panels[index].order = index + 1
        }
        updatePage(page)
    }
    
    private func updatePage(_ page: PanelEditSession.PageEditData) {
        session.pages[session.currentPageIndex] = page
    }
    
    func previousPage() {
        if session.currentPageIndex > 0 { 
            session.currentPageIndex -= 1
            selectedPanelID = nil
            currentLoadedImage = nil // clear memory
            loadImage()
        }
    }
    
    func nextPage() {
        if session.currentPageIndex < session.pages.count - 1 { 
            session.currentPageIndex += 1
            selectedPanelID = nil
            currentLoadedImage = nil // clear memory
            loadImage()
        }
    }
    
    func saveAndComplete() {
        onComplete(session)
    }
}
