import SwiftUI
import Vision
import AVFoundation
import PencilKit

struct PrecisionCanvasView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdf: ConvertedPDF
    @Binding var pageIndex: Int
    let totalCount: Int
    
    @StateObject private var editorState: PageEditorState
    @State private var pageImage: UIImage?
    @State private var selectedTool: WorkAreaToolbar.ToolType = .edit
    @State private var zoomScale: CGFloat = 1.0
    @State private var viewSize: CGSize = .zero
    
    // PencilKit State
    @State private var drawing: PKDrawing = PKDrawing()
    @State private var canvasView = PKCanvasView()
    
    // Geometry State
    @State private var dragStart:  NormalizedCoordinate?
    @State private var currentDragRect: NormalizedRect?
    
    init(pdf: ConvertedPDF, pageIndex: Binding<Int>, totalCount: Int, conversionManager: ConversionManager) {
        self.pdf = pdf
        self._pageIndex = pageIndex
        self.totalCount = totalCount
        
        let initialModel = PageModelStore.shared.getPageModel(for: pdf.id, pageIndex: pageIndex.wrappedValue)
        let undoManager = UndoManager()
        _editorState = StateObject(wrappedValue: PageEditorState(pageModel: initialModel, undoManager: undoManager))
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // MARK: - Main Canvas
            if let image = pageImage {
                GeometryReader { geo in
                    let displayedRect = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: geo.size))
                    
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                        
                        // Panels Overlay
                        Canvas { context, size in
                            // Draw Active Panels
                            for (index, panel) in editorState.pageModel.panels.enumerated() {
                                let rect = CoordinateConverter.denormalize(rect: panel, in: displayedRect)
                                let isSelected = (index == editorState.selectedPanelIndex)
                                
                                // Fill
                                context.fill(Path(rect), with: .color(Color.blue.opacity(0.1)))
                                
                                // Stroke
                                let path = Path(rect)
                                context.stroke(path, with: .color(isSelected ? .yellow : .blue), lineWidth: isSelected ? 3 : 2)
                                
                                // Label
                                let text = Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                
                                let textPoint = CGPoint(x: rect.minX + 4, y: rect.minY + 4)
                                context.draw(text, at: textPoint, anchor: .topLeading)
                            }
                            
                            // Draw Proposed Panels
                            if selectedTool == .scan {
                                for panel in editorState.pageModel.proposedPanels {
                                    let rect = CoordinateConverter.denormalize(rect: panel, in: displayedRect)
                                    let path = Path(rect)
                                    // Thinner, less opaque green
                                    context.stroke(path, with: .color(Color.green.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                }
                            }
                            
                            // Draw Snap Guides
                            if selectedTool == .edit || selectedTool == .anchor {
                                for guide in editorState.snapGuides {
                                    let start = CoordinateConverter.denormalize(point: NormalizedCoordinate(x: guide.type == .vertical ? guide.value : 0, y: guide.type == .horizontal ? guide.value : 0), in: displayedRect)
                                    let end = CoordinateConverter.denormalize(point: NormalizedCoordinate(x: guide.type == .vertical ? guide.value : 1000, y: guide.type == .horizontal ? guide.value : 1000), in: displayedRect)
                                    
                                    var path = Path()
                                    path.move(to: start)
                                    path.addLine(to: end)
                                    
                                    context.stroke(path, with: .color(.blue.opacity(0.15)), lineWidth: 1)
                                }
                            }
                            
                            // 2. Active Snap Guides
                            for guide in activeSnapGuides {
                                let start = CoordinateConverter.denormalize(point: NormalizedCoordinate(x: guide.type == .vertical ? guide.value : 0, y: guide.type == .horizontal ? guide.value : 0), in: displayedRect)
                                let end = CoordinateConverter.denormalize(point: NormalizedCoordinate(x: guide.type == .vertical ? guide.value : 1000, y: guide.type == .horizontal ? guide.value : 1000), in: displayedRect)
                                
                                var path = Path()
                                path.move(to: start)
                                path.addLine(to: end)
                                
                                context.stroke(path, with: .color(.cyan), lineWidth: 2)
                                context.stroke(path, with: .color(.cyan.opacity(0.5)), lineWidth: 4)
                            }
                            
                            // Draw Dragging Rect
                            if let dragRect = currentDragRect {
                                let rect = CoordinateConverter.denormalize(rect: dragRect, in: displayedRect)
                                context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
                                
                                // Draw Handles if Resizing
                                if activeHandle != nil {
                                    let handles = getHandleRects(for: rect)
                                    for handle in handles {
                                        context.fill(Path(handle), with: .color(.white))
                                        context.stroke(Path(handle), with: .color(.black), lineWidth: 1)
                                    }
                                }
                            } else if let index = editorState.selectedPanelIndex {
                                // Draw Handles for Selected Panel (Idle)
                                let rect = CoordinateConverter.denormalize(rect: editorState.pageModel.panels[index], in: displayedRect)
                                let handles = getHandleRects(for: rect)
                                for handle in handles {
                                    context.fill(Path(handle), with: .color(.white))
                                    context.stroke(Path(handle), with: .color(.blue), lineWidth: 1)
                                }
                            }
                            
                            // Anchor Tool Visuals
                            if selectedTool == .anchor {
                                if let dragRect = currentDragRect {
                                    let rect = CoordinateConverter.denormalize(rect: dragRect, in: displayedRect)
                                    context.fill(Path(rect), with: .color(.green.opacity(0.3)))
                                    context.stroke(Path(rect), with: .color(.green), lineWidth: 2)
                                    
                                    // Removed broken text resolver that was erroring during layout passes
                                }
                            }
                        }
                        .gesture(canvasGesture(in: displayedRect))
                    }
                    .onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in viewSize = newSize }
                    
                    // MARK: - PencilKit Overlay
                    // Overlay PencilKit specifically over the image geometry
                    if selectedTool == .draw {
                        PencilKitDrawView(canvas: $canvasView)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .position(x: geo.frame(in: .local).midX, y: geo.frame(in: .local).midY)
                    }
                }
                .edgesIgnoringSafeArea(.top) // Allow canvas to go behind status bar
                .supportPencilDoubleTap {
                    if selectedTool == .anchor {
                        selectedTool = .edit
                        editorState.log("Switched to Edit Placement")
                    } else {
                        selectedTool = .anchor
                        editorState.log("Switched to Add Panel")
                    }
                }
            } else {
                ProgressView("Loading Page...")
                    .foregroundColor(.white)
            }
            
            // MARK: - Security Overlay
            if pdf.isPrivate {
               FaceIDOverlay()
            }
            
            // Processing Overlay
            if editorState.isProcessing {
                Color.black.opacity(0.4)
                    .overlay(ProgressView().tint(.white))
                    .ignoresSafeArea()
            }
        }
        .navigationTitle("Page \(pageIndex + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if pageIndex > 0 {
                        Button(action: {
                            PageModelStore.shared.savePageModel(editorState.pageModel, for: pdf.id)
                            pageIndex -= 1
                        }) {
                            Image(systemName: "chevron.left")
                        }
                    }
                    if pageIndex < totalCount - 1 {
                        Button(action: {
                            PageModelStore.shared.savePageModel(editorState.pageModel, for: pdf.id)
                            pageIndex += 1
                        }) {
                            Image(systemName: "chevron.right")
                        }
                    }

                    Button(action: { withAnimation { editorState.undo() } }) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!editorState.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    
                    Button(action: { withAnimation { editorState.redo() } }) {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!editorState.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    
                    if let index = editorState.selectedPanelIndex {
                        Button(role: .destructive, action: {
                            withAnimation {
                                if index < editorState.pageModel.panels.count {
                                    let rect = editorState.pageModel.panels[index]
                                    editorState.execute(.removePanel(index: index, rect: rect))
                                    editorState.selectedPanelIndex = nil
                                    currentDragRect = nil
                                }
                            }
                        }) {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                    }
                    
                    if !editorState.pageModel.proposedPanels.isEmpty {
                        Button("Commit") {
                            withAnimation { editorState.commitProposals() }
                        }
                        .bold()
                        .foregroundColor(.green)
                    }
                }
            }
            
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button(action: runScan) {
                    VStack(spacing: 4) { Image(systemName: "sparkles"); Text("Scan").font(.caption2) }
                }
                
                Spacer()
                
                Button(action: { selectedTool = .edit }) {
                    VStack(spacing: 4) { Image(systemName: "cursorarrow.rays"); Text("Edit").font(.caption2) }
                }
                .foregroundColor(selectedTool == .edit ? .blue : .primary)
                
                Spacer()
                
                Button(action: { selectedTool = .knife }) {
                    VStack(spacing: 4) { Image(systemName: "scissors"); Text("Split").font(.caption2) }
                }
                .foregroundColor(selectedTool == .knife ? .blue : .primary)
                
                Spacer()
                
                Button(action: { selectedTool = .anchor }) {
                    VStack(spacing: 4) { Image(systemName: "plus.square.dashed"); Text("Add").font(.caption2) }
                }
                .foregroundColor(selectedTool == .anchor ? .blue : .primary)
                
                Spacer()
                
                Button(action: { selectedTool = .draw }) {
                    VStack(spacing: 4) { Image(systemName: "pencil.tip"); Text("Draw").font(.caption2) }
                }
                .foregroundColor(selectedTool == .draw ? .blue : .primary)
                
                Spacer()
                
                Button(action: { selectedTool = .preview }) {
                    VStack(spacing: 4) { Image(systemName: "eye"); Text("Preview").font(.caption2) }
                }
                .foregroundColor(selectedTool == .preview ? .blue : .primary)
                Spacer()
            }
        }
        .background(
            // Hidden Keyboard Shortcuts
            Group {
                Button("") { if pageIndex > 0 { PageModelStore.shared.savePageModel(editorState.pageModel, for: pdf.id); pageIndex -= 1 } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .opacity(0)
                Button("") { if pageIndex < totalCount - 1 { PageModelStore.shared.savePageModel(editorState.pageModel, for: pdf.id); pageIndex += 1 } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .opacity(0)
            }
        )
        .task {
            loadPage()
        }
        .onChange(of: pageIndex) { _, newIndex in
            // When page traversing, instantly load new page without destroying view
            let newModel = PageModelStore.shared.getPageModel(for: pdf.id, pageIndex: newIndex)
            editorState.pageModel = newModel
            editorState.selectedPanelIndex = nil
            currentDragRect = nil
            selectedTool = .edit
            loadPage()
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedTool == .preview },
            set: { if !$0 { selectedTool = .edit } }
        )) {
            if let image = pageImage {
                 let previewPanels = editorState.pageModel.panels.map { p in
                     CGRect(x: p.x / 1000.0, y: p.y / 1000.0, width: p.width / 1000.0, height: p.height / 1000.0)
                 }
                 GuidedViewPreview(image: image, panels: previewPanels)
            } else {
                Color.black.edgesIgnoringSafeArea(.all) // Fallback
            }
        }
        .onDisappear {
            // ✅ Auto-save changes when leaving the page
            PageModelStore.shared.savePageModel(editorState.pageModel, for: pdf.id)
            // ✅ Clean up temporary files when closing editor
            conversionManager.endSession()
        }
    }
    

    @State private var activeSnapGuides: [SnapGuide] = []
    
    // Resize State
    enum ResizeHandle { case topLeft, topEdge, topRight, rightEdge, bottomRight, bottomEdge, bottomLeft, leftEdge }
    @State private var activeHandle: ResizeHandle? = nil

    // MARK: - Logic
    
    private func loadPage() {
        Task {
             if let image = try await conversionManager.extractFullPage(from: pdf, index: pageIndex) {
                  await MainActor.run {
                      self.pageImage = image
                      editorState.log("Page loaded successfully")
                  }
                  
                  // 🧠 Run Magnetic Engine (Gutter Detection)
                  _ = await SnapEngine.shared.detectGutters(in: image)
                  await MainActor.run {
                      self.pageImage = image
                      
                      // 🚀 Run Deep Fix for Legacy Panels
                      // ✅ FIX: Use Pixel Dimensions, not Points (image.size)
                      // Legacy data is in Pixels. Vision/Image.size is Points.
                      let pixelSize = CGSize(
                          width: CGFloat(image.cgImage?.width ?? Int(image.size.width)),
                          height: CGFloat(image.cgImage?.height ?? Int(image.size.height))
                      )
                      validateAndFixPanels(for: pixelSize)
                      
                      editorState.log("Page loaded successfully")
                  }
             }
        }
    }
    
    private func saveAndExit() {
        PageModelStore.shared.savePageModel(editorState.pageModel, for: pdf.id)
        dismiss()
    }
    
    private func runScan() {
        guard let image = pageImage else { return }
        editorState.isProcessing = true
        editorState.log("Starting AI Scan...")
        
        Task {
             let detector = EnsemblePanelDetector()
             let detected = await detector.detect(in: image)
             let normalized = detected.map { panel -> NormalizedRect in
                 // Vision (0,0 Bottom-Left) -> Normalized (0-1000 Top-Left)
                 let r = panel.boundingBox
                 // Flip Y: newY = 1.0 - oldY - height
                 let yTopLeft = 1.0 - r.origin.y - r.height
                 return NormalizedRect(x: r.origin.x * 1000, y: yTopLeft * 1000, width: r.width * 1000, height: r.height * 1000)
             }
            
            await MainActor.run {
                editorState.pageModel.proposedPanels = normalized
                editorState.pageModel.coordinateSystem = .normalized // ✅ Tag as Trusted
                editorState.isProcessing = false
                selectedTool = .scan // Change state so the user can immediately see the green proposed panels!
                editorState.log("AI Scan: Found \(normalized.count) panels")
            }
        }
    }
    
    // ✅ Enhanced Logging for Validation
    private func validateAndFixPanels(for imageSize: CGSize) {
        guard !editorState.pageModel.panels.isEmpty else { return }
        
        let panels = editorState.pageModel.panels
        
        // 1. Calculate the bounding union of all panels
        var unionRect: CGRect = .null
        for p in panels {
            let rect = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
            unionRect = unionRect.isNull ? rect : unionRect.union(rect)
        }
        
        guard !unionRect.isNull else { return }
        
        // 0. CHECK EXPLICIT TAG
        if editorState.pageModel.coordinateSystem == .normalized {
            editorState.log("✅ Panels are tagged as Normalized. Skipping heuristics.")
            return
        }
        
        editorState.log("🔍 Inspecting Panel Coordinates (Legacy/Unknown)...")
        editorState.log("   - Union Rect: \(unionRect)")
        editorState.log("   - Image Size: \(imageSize)")
        
        var detectedSystem: CoordinateSystem? = nil
        
        // 2. Analyze Bounds
        // 2. Analyze Bounds
        if unionRect.maxX <= 1.1 && unionRect.maxY <= 1.1 {
            detectedSystem = .normalizedZeroOne
        } else {
            // Any value > 1.1 MUST be Pixels.
            // Why? Because "Normalized 0-1000" is an internal format that is converted to 0-1 on save.
            // Therefore, it implies that the persistent store (panelOverrides) ONLY contains 0-1 OR Legacy Pixels.
            // It cannot contain 0-1000.
            detectedSystem = .pixels
            editorState.log("   -> Values > 1.1 detected. Treating as Legacy Pixels.")
        }
        
        // Safety: Ensure valid image size for normalization
        if detectedSystem == .pixels && (imageSize.width < 1 || imageSize.height < 1) {
             editorState.log("⚠️ Cannot repair pixels without valid image size. Aborting.")
             return
        }
        
        if let system = detectedSystem {
            editorState.log("   - Detected System: \(system)")
            
            var fixedPanels: [NormalizedRect] = []
            var changed = false
            
            switch system {
            case .normalizedZeroOne:
                 editorState.log("   -> Action: Scaling up by 1000x")
                 fixedPanels = panels.map { 
                     NormalizedRect(x: $0.x * 1000, y: $0.y * 1000, width: $0.width * 1000, height: $0.height * 1000)
                 }
                 changed = true
                 
            case .pixels:
                 editorState.log("   -> Action: Normalizing from Pixels to 0-1000")
                 fixedPanels = panels.map {
                     NormalizedRect(
                        x: ($0.x / imageSize.width) * 1000.0,
                        y: ($0.y / imageSize.height) * 1000.0,
                        width: ($0.width / imageSize.width) * 1000.0,
                        height: ($0.height / imageSize.height) * 1000.0
                     )
                 }
                 changed = true
                 
            case .normalizedThousand:
                 editorState.log("   -> Action: None (Already correct)")
                 break
            }
            
            if changed {
                editorState.pageModel.panels = fixedPanels
                editorState.log("✅ Validation Complete: Migrated \(fixedPanels.count) panels.")
            }
            
            // ✅ Mark as Trusted for future loads
            editorState.pageModel.coordinateSystem = .normalized
        }
    }

    enum CoordinateSystem {
        case normalizedZeroOne
        case normalizedThousand
        case pixels
    }
    
    // ... handles ...

    // MARK: - Gestures
    
    // ...
    // ...


// ✅ Robust Preview Mask Shape
struct PreviewMaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        // 1. Full Screen Rect
        path.addRect(rect)
        
        // 2. Hole Rect (3:4 Ratio)
        let targetRatio = 3.0/4.0
        var holeRect = rect
        
        if rect.width / rect.height > targetRatio {
            // Screen is wider than target (Pillars needed)
            holeRect.size.width = rect.height * targetRatio
            holeRect.origin.x = (rect.width - holeRect.width) / 2
        } else {
            // Screen is taller than target (Letterbox needed)
            holeRect.size.height = rect.width / targetRatio
            holeRect.origin.y = (rect.height - holeRect.height) / 2
        }
        
        path.addRect(holeRect)
        
        return path
    }
}
    
    // MARK: - Helper for Handles
    private func getHandleRects(for rect: CGRect) -> [CGRect] {
        let size: CGFloat = 32 // Tripped size for explicit Pencil touch grabbing
        return [
            CGRect(x: rect.minX - size/2, y: rect.minY - size/2, width: size, height: size), // TopLeft 0
            CGRect(x: rect.midX - size/2, y: rect.minY - size/2, width: size, height: size), // TopEdge 1
            CGRect(x: rect.maxX - size/2, y: rect.minY - size/2, width: size, height: size), // TopRight 2
            CGRect(x: rect.maxX - size/2, y: rect.midY - size/2, width: size, height: size), // RightEdge 3
            CGRect(x: rect.maxX - size/2, y: rect.maxY - size/2, width: size, height: size),  // BottomRight 4
            CGRect(x: rect.midX - size/2, y: rect.maxY - size/2, width: size, height: size), // BottomEdge 5
            CGRect(x: rect.minX - size/2, y: rect.maxY - size/2, width: size, height: size), // BottomLeft 6
            CGRect(x: rect.minX - size/2, y: rect.midY - size/2, width: size, height: size) // LeftEdge 7
        ]
    }
    
    private func hitTestHandle(at point: CGPoint, for rect: CGRect) -> ResizeHandle? {
        let handles = getHandleRects(for: rect)
        // Hit-testing in reverse order might be useful for overlaps, but list is explicit
        if handles[0].contains(point) { return .topLeft }
        if handles[1].contains(point) { return .topEdge }
        if handles[2].contains(point) { return .topRight }
        if handles[3].contains(point) { return .rightEdge }
        if handles[4].contains(point) { return .bottomRight }
        if handles[5].contains(point) { return .bottomEdge }
        if handles[6].contains(point) { return .bottomLeft }
        if handles[7].contains(point) { return .leftEdge }
        return nil
    }

    // MARK: - Gestures
    
    private func canvasGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = CoordinateConverter.normalize(point: value.location, in: rect)
                
                switch selectedTool {
                case .scan, .preview, .draw:
                    break // No interaction (draw is handled by PencilKit wrapper)
                    
                case .knife:
                    // Visual feedback for knife cut?
                    // Draw a vertical line logic
                    currentDragRect = NormalizedRect(
                        x: point.x,
                        y: 0,
                        width: 0,
                        height: 1000 // Vertical line visual
                    )
                    
                case .edit:
                         // Logic to select access panels
                         if value.translation == .zero { // Tap start
                             // 1. Check Handles First
                             if let index = editorState.selectedPanelIndex {
                                 let currentPanelRect = CoordinateConverter.denormalize(rect: editorState.pageModel.panels[index], in: rect)
                                 if let handle = hitTestHandle(at: value.location, for: currentPanelRect) {
                                     activeHandle = handle
                                     currentDragRect = editorState.pageModel.panels[index]
                                     dragStart = point
                                     return // Start Resizing
                                 }
                             }
                        
                             let hits = hitTestAll(point)
                             if !hits.isEmpty {
                                 // Cycle Selection Logic
                                 if let current = editorState.selectedPanelIndex, let idx = hits.firstIndex(of: current) {
                                     // Provide next panel in the hit list (cycling)
                                     let nextIdx = (idx + 1) % hits.count
                                     let newSelection = hits[nextIdx]
                                     editorState.selectedPanelIndex = newSelection
                                     currentDragRect = editorState.pageModel.panels[newSelection]
                                     editorState.log("Selected Panel \(newSelection + 1) (Cycling \(nextIdx + 1)/\(hits.count))")
                                 } else {
                                     // Select the top-most (first in reversed list is visually top)
                                     // hitTestAll returns indices. We want the one that is "highest" in Z-order.
                                     // The basic hitTest returns the *last* one (highest index).
                                     // Let's verify hitTestAll order.
                                     
                                     // If we just pick the first one from our new hitTestAll...
                                     if let newSelection = hits.first {
                                        editorState.selectedPanelIndex = newSelection
                                        currentDragRect = editorState.pageModel.panels[newSelection]
                                        editorState.log("Selected Panel \(newSelection + 1)")
                                     }
                                 }
                                 
                                 dragStart = point 
                                 activeHandle = nil // Moving, not resizing
                             } else {
                                 editorState.selectedPanelIndex = nil
                                 currentDragRect = nil
                                 activeHandle = nil
                             }
                         } else if let index = editorState.selectedPanelIndex, let start = dragStart, let currentRect = currentDragRect {
                         
                         
                         // Determine mode: Resize or Move
                         if let handle = activeHandle {
                             // Determining mode: Resize or Move
                             // We should apply to `original` panel state to prevent cumulative delta drifting

                             let original = editorState.pageModel.panels[index]
                             var targetRect = original
                             
                             let totalDx = point.x - start.x
                             let totalDy = point.y - start.y
                             
                             switch handle {
                             case .topLeft:
                                 targetRect.origin.x += totalDx
                                 targetRect.origin.y += totalDy
                                 targetRect.size.width -= totalDx
                                 targetRect.size.height -= totalDy
                             case .topEdge:
                                 targetRect.origin.y += totalDy
                                 targetRect.size.height -= totalDy
                             case .topRight:
                                 targetRect.origin.y += totalDy
                                 targetRect.size.width += totalDx
                                 targetRect.size.height -= totalDy
                             case .rightEdge:
                                 targetRect.size.width += totalDx
                             case .bottomLeft:
                                 targetRect.origin.x += totalDx
                                 targetRect.size.width -= totalDx
                                 targetRect.size.height += totalDy
                             case .bottomEdge:
                                 targetRect.size.height += totalDy
                             case .bottomRight:
                                 targetRect.size.width += totalDx
                                 targetRect.size.height += totalDy
                             case .leftEdge:
                                 targetRect.origin.x += totalDx
                                 targetRect.size.width -= totalDx
                             }
                             
                             // Resolve negative sizes
                             if targetRect.width < 10 { targetRect.size.width = 10; targetRect.origin.x = original.maxX - 10 } // Simplified
                             if targetRect.height < 10 { targetRect.size.height = 10; targetRect.origin.y = original.maxY - 10 }
                             
                             // Snap Resize?
                             // ... (Omitted for brevity, good enough for now)
                             
                             currentDragRect = targetRect
                             
                         } else {
                             // Moving Logic
                             // 🧲 Magnetic Drag
                             let dx = point.x - start.x
                             let dy = point.y - start.y
                             
                             let original = editorState.pageModel.panels[index]
                             let targetRect = NormalizedRect(
                                 x: original.x + dx,
                                 y: original.y + dy,
                                 width: original.width,
                                 height: original.height
                             )
                             
                             // Run Snap Engine
                             let (snapped, guides) = SnapEngine.shared.snapMove(
                                 targetRect,
                                 guides: editorState.snapGuides,
                                 otherPanels: editorState.pageModel.panels.filter { $0 != original }
                             )
                             
                             currentDragRect = snapped
                             
                             // Haptics
                             if !guides.isEmpty && activeSnapGuides.isEmpty {
                                 UIImpactFeedbackGenerator(style: .light).impactOccurred()
                             }
                             activeSnapGuides = guides
                         }
                    }
                    
                case .anchor:
                    // Create box
                    if dragStart == nil { dragStart = point }
                    let start = dragStart!
                    
                    let minX = min(start.x, point.x)
                    let minY = min(start.y, point.y)
                    let w = abs(point.x - start.x)
                    let h = abs(point.y - start.y)
                    
                    let rawRect = NormalizedRect(x: minX, y: minY, width: w, height: h)
                    
                    // 🧲 Snap Resize/Creation
                    let (snapped, guides) = SnapEngine.shared.snapRect(
                        rawRect,
                        guides: editorState.snapGuides,
                        otherPanels: editorState.pageModel.panels
                    )
                    
                    currentDragRect = snapped
                    activeSnapGuides = guides
                    
                    if !guides.isEmpty {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred() // Rigid for structural snap
                    }
                }
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    currentDragRect = nil
                    activeSnapGuides = []
                    activeHandle = nil
                }
                
                if selectedTool == .anchor, let rect = currentDragRect {
                     // Add Panel Command
                     if rect.width > 20 && rect.height > 20 { // Minimal size (2% of screen)
                         editorState.execute(.addPanel(rect))
                     }
                }
                
                if selectedTool == .edit, let index = editorState.selectedPanelIndex, let newRect = currentDragRect {
                    // Commit Move OR Resize
                    let oldRect = editorState.pageModel.panels[index]
                    if newRect != oldRect {
                        editorState.execute(.resizePanel(index: index, oldRect: oldRect, newRect: newRect))
                    }
                }
                
                if selectedTool == .knife {
                     // Perform split at line
                     let splitX = CoordinateConverter.normalize(point: value.location, in: rect).x
                     performKnifeSplit(at: splitX)
                }
            }
    }
    
    private func performKnifeSplit(at x: Double) {
        // Find panels crossing this X and split them
        for (index, panel) in editorState.pageModel.panels.enumerated().reversed() {
            if x > panel.minX + 20 && x < panel.maxX - 20 { // Margin to avoid edge cuts
                // Original Panel becomes Left Part
                let oldRect = panel
                var leftRect = oldRect
                leftRect.size.width = x - leftRect.origin.x
                
                // New Panel becomes Right Part
                var rightRect = oldRect
                rightRect.origin.x = x
                rightRect.size.width = oldRect.maxX - x
                
                // Composite Command?
                // For now, simpler: Update old one, add new one.
                // But we want single undo. 
                // PageCommand doesn't have "Split".
                // We'll just Add Panel for right, and Resize Panel for left.
                // This will be two steps on undo stack unless we group them.
                // Implementing grouped command is better, but for now let's just do it.
                
                editorState.execute(.resizePanel(index: index, oldRect: oldRect, newRect: leftRect))
                editorState.execute(.addPanel(rightRect))
                break // Only split one top-most panel? Or all? Usually one.
            }
        }
    }
    
    private func hitTestAll(_ point: NormalizedCoordinate) -> [Int] {
        // Find ALL panels containing point, sorted by Z-order (Top/Highest Index -> Bottom/Lowest Index)
        var hits: [Int] = []
        for (index, panel) in editorState.pageModel.panels.enumerated().reversed() {
            if point.x >= panel.minX && point.x <= panel.maxX &&
               point.y >= panel.minY && point.y <= panel.maxY {
                hits.append(index)
            }
        }
        return hits
    }

    private func hitTest(_ point: NormalizedCoordinate) -> Int? {
        return hitTestAll(point).first
    }
}

extension View {
    func invertedMask() -> some View {
        return self // Placeholder
    }
    
    @ViewBuilder
    func supportPencilDoubleTap(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.5, *) {
            self.onPencilDoubleTap { _ in
                Logger.shared.log("Pencil Double-Tap Handled (iOS 17.5+ Native Swift)", category: "Interaction")
                action() 
            }
        } else {
            // Apply as an invisible OVERLAY so it intercepts the hardware delegate priority 
            // BEFORE PencilKit consumes the gesture at the bottom of the ZStack.
            self.overlay(
                PencilDoubleTapResponder(action: action)
                    .allowsHitTesting(false) // Do not block physical finger touch inputs
            )
        }
    }
}

// MARK: - Legacy Apple Pencil Support (< iOS 17.5)
struct PencilDoubleTapResponder: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true // Required to receive touches/interactions
        
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject, UIPencilInteractionDelegate {
        var action: () -> Void
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            Logger.shared.log("Pencil Double-Tap Handled (iOS <17.5 UIKit Bridge)", category: "Interaction")
            action()
        }
    }
}
