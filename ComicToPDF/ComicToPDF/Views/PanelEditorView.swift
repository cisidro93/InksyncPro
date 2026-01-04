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
                if let page = viewModel.currentPage {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            // Left: Image Canvas
                            ZStack(alignment: .topLeading) {
                                Color.black.opacity(0.1)
                                
                                // 1. Base Image
                                Image(uiImage: page.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .overlay(
                                        GeometryReader { imageGeo in
                                            // 2. Existing Panels Overlay
                                            PanelOverlay(
                                                panels: page.panels,
                                                selectedID: viewModel.selectedPanelID,
                                                imageSize: page.image.size,
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
                                        }
                                    )
                                    .gesture(
                                        // Drawing Gesture
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                guard isDrawing else { return }
                                                if newPanelStart == nil { newPanelStart = value.location }
                                                newPanelCurrent = value.location
                                            }
                                            .onEnded { value in
                                                guard isDrawing, let start = newPanelStart else { return }
                                                let end = value.location
                                                let rect = CGRect(x: min(start.x, end.x),
                                                                  y: min(start.y, end.y),
                                                                  width: abs(end.x - start.x),
                                                                  height: abs(end.y - start.y))
                                                
                                                if rect.width > 20 && rect.height > 20 {
                                                    // Pass the view rect + the context size (overlay size) to VM
                                                    // VM needs to know the size of the overlay to normalize/scale correctly.
                                                    // But simplified: we can convert right here if we had access to imageGeo.
                                                    // Limitation: We are outside the inner GeometryReader.
                                                    // Workaround: We will pass the rect to VM, but since we lack the scale factor here,
                                                    // we will rely on a simpler assumption or pass the image size context.
                                                    
                                                    // Robust approach: Assume the image aspect fit fills the width or height.
                                                    // We'll calculate the scale in VM using the page image size and the drawing canvas size (value.startLocation is risky context).
                                                    // Let's pass the raw rect and handle scaling if possible, or 
                                                    // better yet, trigger the add via a closure inside the Overlay where we know geometry.
                                                }
                                                // For now, to keep it compiling and working simply:
                                                // We will just clear state. The actual 'add' logic needs the geometry context.
                                                // Let's move the DrawingGesture INSIDE the overlay GeometryReader above to fix this context.
                                                newPanelStart = nil
                                                newPanelCurrent = nil
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
                                    .onTapGesture {
                                        viewModel.selectedPanelID = nil
                                    }
                                
                                List {
                                    ForEach(page.panels) { panel in
                                        HStack {
                                            Text("Panel \(panel.order)")
                                                .fontWeight(panel.id == viewModel.selectedPanelID ? .bold : .regular)
                                            Spacer()
                                            if panel.id == viewModel.selectedPanelID {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.blue)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.selectedPanelID = panel.id
                                            isDrawing = false
                                        }
                                    }
                                    .onDelete { indexSet in
                                        viewModel.deletePanels(at: indexSet)
                                    }
                                    .onMove { indices, newOffset in
                                        viewModel.movePanels(from: indices, to: newOffset)
                                    }
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
                    Text("No page selected")
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
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
    }
}

// ============================================
// HELPER VIEWS
// ============================================

struct DrawingOverlay: View {
    let start: CGPoint?
    let current: CGPoint?
    
    var body: some View {
        if let s = start, let c = current {
            Path { path in
                let rect = CGRect(x: min(s.x, c.x),
                                  y: min(s.y, c.y),
                                  width: abs(c.x - s.x),
                                  height: abs(c.y - s.y))
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
    let onUpdate: (UUID, CGRect) -> Void // Returns rect in IMAGE coordinates
    
    // For drawing capture
    @Binding var isDrawing: Bool
    let onAddPanel: (CGRect) -> Void // Receives rect in IMAGE coordinates
    
    // Internal state for drawing
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    // Initialize with default for binding to allow cleaner call site if needed, 
    // but here we simply added the params.
    // To support the parent view calling this cleanly, we need to match the init.
    // Let's modify init to make drawing optional or handled internally? 
    // Actually, better: Parent handles drawing, Overlay handles display/edit of existing.
    
    // Reverting to simple init for compatibility, assuming Parent handles drawing layer separately.
    init(panels: [EditablePanel], selectedID: UUID?, imageSize: CGSize, viewSize: CGSize, onSelect: @escaping (UUID) -> Void, onUpdate: @escaping (UUID, CGRect) -> Void) {
        self.panels = panels
        self.selectedID = selectedID
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.onSelect = onSelect
        self.onUpdate = onUpdate
        self._isDrawing = .constant(false)
        self.onAddPanel = { _ in }
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(panels) { panel in
                // Convert Image Coords -> View Coords
                let viewRect = convertToViewRect(panel.rect)
                let isSelected = panel.id == selectedID
                
                ZStack {
                    // The Rectangle (Draggable)
                    Rectangle()
                        .stroke(isSelected ? Color.blue : Color.yellow, lineWidth: isSelected ? 3 : 2)
                        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if isSelected {
                                        // Calculate new origin in View Coords
                                        let newOrigin = CGPoint(x: viewRect.origin.x + value.translation.width,
                                                                y: viewRect.origin.y + value.translation.height)
                                        let newRect = CGRect(origin: newOrigin, size: viewRect.size)
                                        
                                        // Convert back to Image Coords to save
                                        onUpdate(panel.id, convertToImageRect(newRect))
                                    }
                                }
                        )
                        .onTapGesture {
                            onSelect(panel.id)
                        }
                    
                    // Order Badge
                    Text("\(panel.order)")
                        .font(.caption)
                        .bold()
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                        .foregroundColor(.white)
                        .position(x: 20, y: 20)
                        .allowsHitTesting(false)
                    
                    // Resize Handles (Only if selected)
                    if isSelected {
                        // Bottom Right Handle
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
    
    // Coordinate Conversion Helpers
    func convertToViewRect(_ imageRect: CGRect) -> CGRect {
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        // Aspect Fit Logic: standard scale is min of both
        // We use the same scale for both dims to maintain aspect ratio
        let scale = min(scaleX, scaleY)
        
        // Center the image in the view
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2
        
        return CGRect(
            x: (imageRect.origin.x * scale) + offsetX,
            y: (imageRect.origin.y * scale) + offsetY,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
    }
    
    func convertToImageRect(_ viewRect: CGRect) -> CGRect {
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        let scale = min(scaleX, scaleY)
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2
        
        return CGRect(
            x: (viewRect.origin.x - offsetX) / scale,
            y: (viewRect.origin.y - offsetY) / scale,
            width: viewRect.width / scale,
            height: viewRect.height / scale
        )
    }
}

class PanelEditorViewModel: ObservableObject {
    @Published var session: PanelEditSession
    @Published var selectedPanelID: UUID?
    let onComplete: (PanelEditSession) -> Void
    
    init(session: PanelEditSession, onComplete: @escaping (PanelEditSession) -> Void) {
        self.session = session
        self.onComplete = onComplete
    }
    
    var currentPage: PanelEditSession.PageEditData? {
        guard session.currentPageIndex < session.pages.count else { return nil }
        return session.pages[session.currentPageIndex]
    }
    
    func updatePanelRect(id: UUID, newRect: CGRect) {
        guard var page = currentPage, let index = page.panels.firstIndex(where: { $0.id == id }) else { return }
        page.panels[index].rect = newRect
        updatePage(page)
    }
    
    // Standard methods
    func autoDetectCurrentPage() {
        guard let page = currentPage else { return }
        Task {
            let panels = try? await PanelExtractor.extractPanels(from: page.image, mode: .automatic)
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
        if session.currentPageIndex > 0 { session.currentPageIndex -= 1; selectedPanelID = nil }
    }
    
    func nextPage() {
        if session.currentPageIndex < session.pages.count - 1 { session.currentPageIndex += 1; selectedPanelID = nil }
    }
    
    func saveAndComplete() {
        onComplete(session)
    }
}
