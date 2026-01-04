import SwiftUI
import ImageIO

struct PanelEditorView: View {
    @ObservedObject var session: PanelEditSession
    var onComplete: (PanelEditSession) -> Void
    var onCancel: () -> Void
    
    @State private var currentIndex: Int = 0
    @State private var selectedPanelID: UUID?
    @State private var showHelp: Bool = false
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // --- HEADER ---
                HStack {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.white)
                    Spacer()
                    Text("Page \(currentIndex + 1) of \(session.pages.count)")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button("Done") { onComplete(session) }
                        .font(.headline)
                        .foregroundColor(.orange)
                }
                .padding()
                .background(Color.gray.opacity(0.2))
                
                // --- MAIN CONTENT ---
                // ✅ FIX: GeometryReader wraps the TabView to provide stable size
                GeometryReader { mainGeo in
                    TabView(selection: $currentIndex) {
                        ForEach(session.pages.indices, id: \.self) { index in
                            let page = session.pages[index]
                            // We pass the OUTER geometry down to the page
                            PageView(
                                page: page,
                                selectedPanelID: $selectedPanelID,
                                geometry: mainGeo, 
                                onAddPanel: { rect in
                                    addPanel(to: page, rect: rect)
                                },
                                onDeletePanel: { id in
                                    deletePanel(from: page, id: id)
                                },
                                onUpdatePanel: { id, rect in
                                    updatePanel(in: page, id: id, rect: rect)
                                }
                            )
                            .tag(index) // Use index for tag to match selection
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                }
                
                // --- FOOTER ---
                VStack(spacing: 12) {
                    HStack {
                        Text("Detected: \(currentPanels.count)")
                            .foregroundColor(.gray)
                        Spacer()
                        Button(action: { showHelp.toggle() }) {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button(action: { autoDetect() }) {
                                Label("Re-Detect", systemImage: "sparkles")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.blue)
                                    .cornerRadius(8)
                            }
                            
                            Button(action: { clearPanels() }) {
                                Label("Clear All", systemImage: "trash")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(8)
                            }
                            
                            if let selected = selectedPanelID {
                                Button(action: { deletePanel(id: selected) }) {
                                    Label("Delete Selected", systemImage: "xmark.circle")
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.orange)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.2))
            }
        }
        .alert(isPresented: $showHelp) {
            Alert(title: Text("How to Edit"), message: Text("• Tap a panel to select it\n• Drag corners to resize\n• Tap 'x' to delete\n• Drag on empty space to draw a new panel"), dismissButton: .default(Text("Got it")))
        }
    }
    
    // MARK: - Logic
    
    private var currentPanels: [EditablePanel] {
        guard currentIndex < session.pages.count else { return [] }
        return session.pages[currentIndex].panels
    }
    
    private func addPanel(to page: PanelEditSession.PageEditData, rect: CGRect) {
        if let idx = session.pages.firstIndex(where: { $0.id == page.id }) {
            let newOrder = (session.pages[idx].panels.map { $0.order }.max() ?? 0) + 1
            let panel = EditablePanel(id: UUID(), rect: rect, order: newOrder)
            session.pages[idx].panels.append(panel)
            selectedPanelID = panel.id
        }
    }
    
    private func deletePanel(from page: PanelEditSession.PageEditData, id: UUID) {
        if let idx = session.pages.firstIndex(where: { $0.id == page.id }) {
            session.pages[idx].panels.removeAll(where: { $0.id == id })
            if selectedPanelID == id { selectedPanelID = nil }
        }
    }
    
    private func deletePanel(id: UUID) {
        guard currentIndex < session.pages.count else { return }
        session.pages[currentIndex].panels.removeAll(where: { $0.id == id })
        selectedPanelID = nil
    }
    
    private func updatePanel(in page: PanelEditSession.PageEditData, id: UUID, rect: CGRect) {
        if let idx = session.pages.firstIndex(where: { $0.id == page.id }),
           let panelIdx = session.pages[idx].panels.firstIndex(where: { $0.id == id }) {
            session.pages[idx].panels[panelIdx].rect = rect
        }
    }
    
    private func autoDetect() {
        print("Auto-detect requested")
    }
    
    private func clearPanels() {
        guard currentIndex < session.pages.count else { return }
        session.pages[currentIndex].panels.removeAll()
        selectedPanelID = nil
    }
}

// MARK: - PageView & Helpers

struct PageView: View {
    let page: PanelEditSession.PageEditData
    @Binding var selectedPanelID: UUID?
    let geometry: GeometryProxy
    let onAddPanel: (CGRect) -> Void
    let onDeletePanel: (UUID) -> Void
    let onUpdatePanel: (UUID, CGRect) -> Void
    
    @State private var originalImageSize: CGSize? = nil
    @State private var newPanelStart: CGPoint?
    @State private var newPanelCurrent: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Image
            OptimizedPageImage(url: page.imageURL, targetSize: geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle()) // Ensure tap/drag works on empty areas
            
            // 2. Overlays
            if let imgSize = originalImageSize {
                PanelOverlay(
                    panels: page.panels,
                    selectedID: selectedPanelID,
                    imageSize: imgSize,
                    viewSize: geometry.size,
                    onSelect: { id in selectedPanelID = id },
                    onUpdate: { id, rect in onUpdatePanel(id, rect) }
                )
                
                // Drawing
                if let start = newPanelStart, let current = newPanelCurrent {
                    DrawingOverlay(start: start, current: current)
                }
                
                // Gestures
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
                                let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                                
                                if rect.width > 20 && rect.height > 20 {
                                    // Convert to Image Coords
                                    let scaleX = imgSize.width / geometry.size.width
                                    let scaleY = imgSize.height / geometry.size.height
                                    let imageRect = CGRect(x: rect.origin.x * scaleX, y: rect.origin.y * scaleY,
                                                           width: rect.width * scaleX, height: rect.height * scaleY)
                                    onAddPanel(imageRect)
                                }
                                newPanelStart = nil
                                newPanelCurrent = nil
                            }
                    )
                    .allowsHitTesting(selectedPanelID == nil) // Only draw if no panel selected? Or always?
                    // User said "Drag on empty space". If over a panel, PanelOverlay handles (if selected).
                    // If not selected, we might want to select it.
                    // PanelOverlay has onTapGesture.
            }
        }
        .task {
            // Load original dimensions for coordinate mapping
            if originalImageSize == nil {
                originalImageSize = ImageUtilities.getImageSize(url: page.imageURL)
            }
        }
    }
}

// Re-use helper views
struct DrawingOverlay: View {
    let start: CGPoint
    let current: CGPoint
    var body: some View {
        Path { path in
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            path.addRect(rect)
        }
        .stroke(Color.green, lineWidth: 2)
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
                        
                    if isSelected {
                        // resize handle
                         Circle()
                            .fill(Color.blue)
                            .frame(width: 20, height: 20)
                            .position(x: viewRect.width, y: viewRect.height) // simplified handle pos
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let newW = max(20, viewRect.width + value.translation.width)
                                        let newH = max(20, viewRect.height + value.translation.height)
                                        let newR = CGRect(x: viewRect.origin.x, y: viewRect.origin.y, width: newW, height: newH)
                                        onUpdate(panel.id, convertToImageRect(newR))
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

struct OptimizedPageImage: View {
    let url: URL
    let targetSize: CGSize
    
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        ZStack {
            Color.gray.opacity(0.1)
            
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else if let errorMessage = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Failed to Load")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
            } else {
                VStack {
                    ProgressView()
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .task(id: targetSize) { await loadImage() }
        .task(id: url) { await loadImage() }
    }
    
    private func loadImage() async {
        guard targetSize.width > 0 && targetSize.height > 0 else {
            print("⏳ OptimizedPageImage: Waiting for valid layout size...")
            return
        }
        await MainActor.run {
            self.errorMessage = nil
            if self.image == nil { self.isLoading = true }
        }
        let currentURL = url
        let size = targetSize
        // FIX: Capture scale on MainActor before detached task
        let scale = await MainActor.run { UIScreen.main.scale }

        let result = await Task.detached(priority: .userInitiated) { () -> Result<UIImage, Error> in
            guard FileManager.default.fileExists(atPath: currentURL.path) else {
                return .failure(NSError(domain: "ImageLoader", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found at path"]))
            }
            if let img = ImageUtilities.downsample(imageAt: currentURL, to: size, scale: scale) {
                return .success(img)
            } else {
                return .failure(NSError(domain: "ImageLoader", code: 500, userInfo: [NSLocalizedDescriptionKey: "Downsampling failed"]))
            }
        }.value
        await MainActor.run {
            self.isLoading = false
            switch result {
            case .success(let img): withAnimation { self.image = img }
            case .failure(let err): self.errorMessage = err.localizedDescription
            }
        }
    }
}

struct ImageUtilities {
    static func downsample(imageAt imageURL: URL, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions) else { return nil }
        
        // Ensure we don't pass 0 to ImageIO
        let maxDim = max(pointSize.width, pointSize.height) * scale
        let targetPixels = max(maxDim, 1024) 
        
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixels
        ] as CFDictionary
        
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: downsampledImage)
    }

    static func getImageSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        if let width = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight as String] as? CGFloat {
            return CGSize(width: width, height: height)
        }
        return nil
    }
}

