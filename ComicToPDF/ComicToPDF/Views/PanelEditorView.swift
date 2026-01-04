
// MARK: - Canvas Components

struct PanelCanvasView: View {
    let page: PanelEditSession.PageEditData?
    @Binding var selectedPanelID: UUID?
    let onPanelUpdate: (EditablePanel) -> Void
    let onAddPanel: (CGRect) -> Void
    let canvasSize: CGSize
    
    @State private var isDraggingNewPanel = false
    @State private var newPanelStart: CGPoint = .zero
    @State private var newPanelCurrent: CGPoint = .zero
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            
            if let page = page {
                GeometryReader { geo in
                    let imageSize = calculateImageSize(for: page.image, in: geo.size)
                    let imageFrame = CGRect(
                        x: (geo.size.width - imageSize.width) / 2,
                        y: (geo.size.height - imageSize.height) / 2,
                        width: imageSize.width,
                        height: imageSize.height
                    )
                    
                    ZStack {
                        // Comic page image
                        Image(uiImage: page.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: imageSize.width, height: imageSize.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        
                        // Panel overlays
                        ForEach(page.panels) { panel in
                            PanelOverlayView(
                                panel: panel,
                                isSelected: selectedPanelID == panel.id,
                                imageFrame: imageFrame,
                                imageSize: CGSize(
                                    width: page.image.size.width,
                                    height: page.image.size.height
                                ),
                                onSelect: {
                                    selectedPanelID = panel.id
                                },
                                onUpdate: { updatedPanel in
                                    onPanelUpdate(updatedPanel)
                                }
                            )
                        }
                        
                        // New panel being drawn
                        if isDraggingNewPanel {
                            let drawRect = rectFromPoints(newPanelStart, newPanelCurrent)
                            Rectangle()
                                .stroke(Color.green, lineWidth: 2)
                                .background(Color.green.opacity(0.1))
                                .frame(width: drawRect.width, height: drawRect.height)
                                .position(x: drawRect.midX, y: drawRect.midY)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                if !isDraggingNewPanel {
                                    // Start drawing new panel
                                    isDraggingNewPanel = true
                                    newPanelStart = value.startLocation
                                    selectedPanelID = nil
                                }
                                newPanelCurrent = value.location
                            }
                            .onEnded { value in
                                if isDraggingNewPanel {
                                    let drawRect = rectFromPoints(newPanelStart, newPanelCurrent)
                                    
                                    // Convert screen coordinates to image coordinates
                                    let imageRect = screenRectToImageRect(
                                        drawRect,
                                        imageFrame: imageFrame,
                                        imageSize: CGSize(
                                            width: page.image.size.width,
                                            height: page.image.size.height
                                        )
                                    )
                                    
                                    // Only create panel if it's large enough
                                    if imageRect.width > 30 && imageRect.height > 30 {
                                        onAddPanel(imageRect)
                                    }
                                    
                                    isDraggingNewPanel = false
                                }
                            }
                    )
                }
            }
        }
    }
    
    private func calculateImageSize(for image: UIImage, in containerSize: CGSize) -> CGSize {
        let imageAspect = image.size.width / image.size.height
        let containerAspect = containerSize.width / containerSize.height
        
        if imageAspect > containerAspect {
            // Image is wider
            let width = containerSize.width * 0.95
            let height = width / imageAspect
            return CGSize(width: width, height: height)
        } else {
            // Image is taller
            let height = containerSize.height * 0.95
            let width = height * imageAspect
            return CGSize(width: width, height: height)
        }
    }
    
    private func rectFromPoints(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        let origin = CGPoint(
            x: min(start.x, end.x),
            y: min(start.y, end.y)
        )
        let size = CGSize(
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        return CGRect(origin: origin, size: size)
    }
    
    private func screenRectToImageRect(_ screenRect: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        let scaleX = imageSize.width / imageFrame.width
        let scaleY = imageSize.height / imageFrame.height
        
        let imageX = (screenRect.origin.x - imageFrame.origin.x) * scaleX
        let imageY = (screenRect.origin.y - imageFrame.origin.y) * scaleY
        let imageWidth = screenRect.width * scaleX
        let imageHeight = screenRect.height * scaleY
        
        return CGRect(x: imageX, y: imageY, width: imageWidth, height: imageHeight)
    }
}

struct PanelOverlayView: View {
    let panel: EditablePanel
    let isSelected: Bool
    let imageFrame: CGRect
    let imageSize: CGSize
    let onSelect: () -> Void
    let onUpdate: (EditablePanel) -> Void
    
    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    
    var body: some View {
        let screenRect = imageRectToScreenRect(panel.rect, imageFrame: imageFrame, imageSize: imageSize)
        
        ZStack {
            // Panel rectangle
            Rectangle()
                .stroke(isSelected ? Color.orange : Color.blue, lineWidth: isSelected ? 3 : 2)
                .background(isSelected ? Color.orange.opacity(0.15) : Color.blue.opacity(0.1))
            
            // Panel number badge
            VStack {
                HStack {
                    Text("\(panel.order)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(isSelected ? Color.orange : Color.blue)
                        .clipShape(Circle())
                        .shadow(radius: 2)
                    Spacer()
                }
                Spacer()
            }
            .padding(4)
            
            // Resize handles (only when selected)
            if isSelected {
                resizeHandles
            }
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .position(x: screenRect.midX, y: screenRect.midY)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    // Calculate new position
                    let newScreenRect = CGRect(
                        x: screenRect.origin.x + value.translation.width,
                        y: screenRect.origin.y + value.translation.height,
                        width: screenRect.width,
                        height: screenRect.height
                    )
                    
                    let newImageRect = screenRectToImageRect(newScreenRect, imageFrame: imageFrame, imageSize: imageSize)
                    
                    var updatedPanel = panel
                    updatedPanel.rect = newImageRect
                    onUpdate(updatedPanel)
                    
                    dragOffset = .zero
                    isDragging = false
                }
        )
        .onTapGesture {
            onSelect()
        }
    }
    
    private var resizeHandles: some View {
        Group {
            // Corner handles
            ForEach([CornerPosition.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 20, height: 20)
                    .position(cornerPosition(for: corner, screenRect: imageRectToScreenRect(panel.rect, imageFrame: imageFrame, imageSize: imageSize)))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Implement drag resizing if needed
                            }
                    )
            }
        }
    }
    
    private func cornerPosition(for corner: CornerPosition, screenRect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:
            return CGPoint(x: 0, y: 0)
        case .topRight:
            return CGPoint(x: screenRect.width, y: 0)
        case .bottomLeft:
            return CGPoint(x: 0, y: screenRect.height)
        case .bottomRight:
            return CGPoint(x: screenRect.width, y: screenRect.height)
        }
    }
    
    private func imageRectToScreenRect(_ imageRect: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        let scaleX = imageFrame.width / imageSize.width
        let scaleY = imageFrame.height / imageSize.height
        
        let screenX = imageFrame.origin.x + (imageRect.origin.x * scaleX)
        let screenY = imageFrame.origin.y + (imageRect.origin.y * scaleY)
        let screenWidth = imageRect.width * scaleX
        let screenHeight = imageRect.height * scaleY
        
        return CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
    }
    
    private func screenRectToImageRect(_ screenRect: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        let scaleX = imageSize.width / imageFrame.width
        let scaleY = imageSize.height / imageFrame.height
        
        let imageX = (screenRect.origin.x - imageFrame.origin.x) * scaleX
        let imageY = (screenRect.origin.y - imageFrame.origin.y) * scaleY
        let imageWidth = screenRect.width * scaleX
        let imageHeight = screenRect.height * scaleY
        
        return CGRect(x: imageX, y: imageY, width: imageWidth, height: imageHeight)
    }
    
    enum CornerPosition {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}

// MARK: - ViewModel

@MainActor
class PanelEditorViewModel: ObservableObject {
    @Published var session: PanelEditSession
    @Published var selectedPanelID: UUID?
    @Published var showingHelp = false
    
    let onComplete: (PanelEditSession) -> Void
    
    init(session: PanelEditSession, onComplete: @escaping (PanelEditSession) -> Void) {
        self.session = session
        self.onComplete = onComplete
    }
    
    var currentPage: PanelEditSession.PageEditData? {
        session.currentPage
    }
    
    var selectedPanel: EditablePanel? {
        guard let id = selectedPanelID,
              let page = currentPage else { return nil }
        return page.panels.first { $0.id == id }
    }
    
    // MARK: - Panel Management
    
    func updatePanel(_ panel: EditablePanel) {
        guard var page = currentPage else { return }
        if let index = page.panels.firstIndex(where: { $0.id == panel.id }) {
            page.panels[index] = panel
            session.updateCurrentPage(page)
        }
    }
    
    func addPanel(rect: CGRect) {
        guard var page = currentPage else { return }
        let newOrder = (page.panels.map { $0.order }.max() ?? 0) + 1
        let newPanel = EditablePanel(rect: rect, order: newOrder)
        page.panels.append(newPanel)
        session.updateCurrentPage(page)
        selectedPanelID = newPanel.id
    }
    
    func deleteSelectedPanel() {
        guard let id = selectedPanelID, var page = currentPage else { return }
        page.panels.removeAll { $0.id == id }
        
        // Renumber remaining panels
        page.panels = page.panels.enumerated().map { index, panel in
            var updated = panel
            updated.order = index + 1
            return updated
        }
        
        session.updateCurrentPage(page)
        selectedPanelID = nil
    }
    
    func moveSelectedPanelUp() {
        guard let id = selectedPanelID, var page = currentPage,
              let index = page.panels.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        
        page.panels.swapAt(index, index - 1)
        page.panels = page.panels.enumerated().map { idx, panel in
            var updated = panel
            updated.order = idx + 1
            return updated
        }
        
        session.updateCurrentPage(page)
    }
    
    func moveSelectedPanelDown() {
        guard let id = selectedPanelID, var page = currentPage,
              let index = page.panels.firstIndex(where: { $0.id == id }),
              index < page.panels.count - 1 else { return }
        
        page.panels.swapAt(index, index + 1)
        page.panels = page.panels.enumerated().map { idx, panel in
            var updated = panel
            updated.order = idx + 1
            return updated
        }
        
        session.updateCurrentPage(page)
    }
    
    func clearCurrentPage() {
        guard var page = currentPage else { return }
        page.panels.removeAll()
        session.updateCurrentPage(page)
        selectedPanelID = nil
    }
    
    func autoDetectCurrentPage() {
        guard var page = currentPage else { return }
        
        Task {
            do {
                let detected = try await PanelExtractor.extractPanels(
                    from: page.image,
                    mode: session.readingDirection == .rightToLeft ? .automatic : .automatic // Use auto for now
                )
                
                await MainActor.run {
                    page.panels = detected.enumerated().map { index, panel in
                        EditablePanel(from: panel, order: index + 1)
                    }
                    session.updateCurrentPage(page)
                }
            } catch {
                print("Auto-detection failed: \(error)")
            }
        }
    }
    
    // MARK: - Navigation
    
    func previousPage() {
        guard session.currentPageIndex > 0 else { return }
        session.currentPageIndex -= 1
        selectedPanelID = nil
    }
    
    func nextPage() {
        guard session.currentPageIndex < session.pages.count - 1 else { return }
        session.currentPageIndex += 1
        selectedPanelID = nil
    }
    
    func saveAndComplete() {
        onComplete(session)
    }
}
