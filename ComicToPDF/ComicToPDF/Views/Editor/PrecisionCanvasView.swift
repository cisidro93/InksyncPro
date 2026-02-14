import SwiftUI
import Vision

struct PrecisionCanvasView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdf: ConvertedPDF
    let pageIndex: Int
    
    @StateObject private var editorState: PageEditorState
    @State private var pageImage: UIImage?
    @State private var selectedTool: WorkAreaToolbar.ToolType = .edit
    @State private var selectedPanelIndex: Int?
    @State private var zoomScale: CGFloat = 1.0
    @State private var viewSize: CGSize = .zero
    
    // Geometry State
    @State private var dragStart:  NormalizedCoordinate?
    @State private var currentDragRect: NormalizedRect?
    
    init(pdf: ConvertedPDF, pageIndex: Int, conversionManager: ConversionManager) {
        self.pdf = pdf
        self.pageIndex = pageIndex
        
        let initialModel = conversionManager.getPageModel(for: pdf.id, pageIndex: pageIndex)
        let undoManager = UndoManager()
        _editorState = StateObject(wrappedValue: PageEditorState(pageModel: initialModel, undoManager: undoManager))
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // MARK: - Main Canvas
            if let image = pageImage {
                GeometryReader { geo in
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
                                let rect = CoordinateConverter.denormalize(rect: panel, in: size)
                                let isSelected = (index == selectedPanelIndex)
                                
                                // Fill
                                context.fill(Path(rect), with: .color(Color.blue.opacity(0.1)))
                                
                                // Stroke
                                var path = Path(rect)
                                context.stroke(path, with: .color(isSelected ? .yellow : .blue), lineWidth: isSelected ? 3 : 2)
                                
                                // Label
                                let text = Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                
                                let textPoint = CGPoint(x: rect.minX + 4, y: rect.minY + 4)
                                context.draw(text, at: textPoint, anchor: .topLeading)
                            }
                            
                            // Draw Proposed Panels (Dashed)
                            for panel in editorState.pageModel.proposedPanels {
                                let rect = CoordinateConverter.denormalize(rect: panel, in: size)
                                var path = Path(rect)
                                context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                            }
                            
                            // Draw Dragging Rect
                            if let dragRect = currentDragRect {
                                let rect = CoordinateConverter.denormalize(rect: dragRect, in: size)
                                context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
                            }
                        }
                        .gesture(canvasGesture(in: geo.size))
                    }
                    .onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { newSize in viewSize = newSize }
                }
                .edgesIgnoringSafeArea(.top) // Allow canvas to go behind status bar
            } else {
                ProgressView("Loading Page...")
                    .foregroundColor(.white)
            }
            
            // MARK: - Toolbar & Overlays (Top)
            VStack {
                HStack {
                    Button("Close") { saveAndExit() }
                        .foregroundColor(.white)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    
                    Spacer()
                    
                    HStack(spacing: 20) {
                        Button {
                            withAnimation { editorState.undo() }
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.title2)
                        }
                        .disabled(!editorState.canUndo)
                        
                        Button {
                            withAnimation { editorState.redo() }
                        } label: {
                            Image(systemName: "arrow.uturn.forward.circle.fill")
                                .font(.title2)
                        }
                        .disabled(!editorState.canRedo)
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .padding()
                
                Spacer()
                
                // MARK: - Toolbar (Bottom)
                WorkAreaToolbar(
                    selectedTool: $selectedTool,
                    isProcessing: $editorState.isProcessing,
                    onScan: runScan,
                    onCommit: {
                        withAnimation { editorState.commitProposals() }
                    },
                    canCommit: !editorState.pageModel.proposedPanels.isEmpty
                )
            }
            
                if selectedTool == .preview {
                     // Kindle Scribe Simulator (3:4 Ratio Mask)
                     GeometryReader { overlayGeo in
                         let targetRatio = 3.0 / 4.0
                         let currentRatio = overlayGeo.size.width / overlayGeo.size.height
                         
                         if currentRatio > targetRatio {
                             // Too wide, pillars
                             HStack {
                                 Color.black.opacity(0.8)
                                 Spacer()
                                 Color.black.opacity(0.8)
                             }
                         } else {
                             // Too tall, letterbox
                             VStack {
                                 Color.black.opacity(0.8)
                                 Spacer()
                                 Color.black.opacity(0.8)
                             }
                         }
                     }
                     .ignoresSafeArea()
                     .allowsHitTesting(false)
                }

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
        .onAppear { loadPage() }
        .secureVaultPrivacy() // Apply the modifier we created earlier
    }
    
    // MARK: - Logic
    
    private func loadPage() {
        Task {
            if let image = try await conversionManager.extractFullPage(from: pdf, index: pageIndex) {
                 await MainActor.run {
                     self.pageImage = image
                 }
            }
        }
    }
    
    private func saveAndExit() {
        conversionManager.savePageModel(editorState.pageModel, for: pdf.id)
        dismiss()
    }
    
    private func runScan() {
        guard let image = pageImage else { return }
        editorState.isProcessing = true
        
        Task {
             let detected = await PanelExtractor.detectPanels(in: image)
             let normalized = detected.map { panel -> NormalizedRect in
                 // Vision (0,0 Bottom-Left) -> Normalized (0-1000 Top-Left)
                 let r = panel.boundingBox
                 // Flip Y: newY = 1.0 - oldY - height
                 let yTopLeft = 1.0 - r.origin.y - r.height
                 return NormalizedRect(x: r.origin.x * 1000, y: yTopLeft * 1000, width: r.width * 1000, height: r.height * 1000)
             }
            
            await MainActor.run {
                editorState.pageModel.proposedPanels = normalized
                editorState.isProcessing = false
            }
        }
    }
    
    // MARK: - Gestures
    
    private func canvasGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = CoordinateConverter.normalize(point: value.location, in: size)
                
                switch selectedTool {
                case .scan, .preview:
                    break // No interaction
                    
                case .knife:
                    // Visual feedback for knife cut?
                    // Draw a vertical line logic
                    currentDragRect = NormalizedRect(
                        origin: NormalizedCoordinate(x: point.x, y: 0),
                        size: NormalizedSize(width: 0, height: 1000) // Vertical line visual
                    )
                    
                case .edit:
                    // Logic to select access panels
                    // Simple hit test
                    if value.translation == .zero { // Tap start
                         if let index = hitTest(point) {
                             selectedPanelIndex = index
                         } else {
                             selectedPanelIndex = nil
                         }
                    } else if let index = selectedPanelIndex {
                         // Dragging panel logic (simplified for now)
                         // Ideally we'd move the panel here
                    }
                    
                case .anchor:
                    // Create box
                    if dragStart == nil { dragStart = point }
                    let start = dragStart!
                    
                    let minX = min(start.x, point.x)
                    let minY = min(start.y, point.y)
                    let w = abs(point.x - start.x)
                    let h = abs(point.y - start.y)
                    
                    currentDragRect = NormalizedRect(x: minX, y: minY, width: w, height: h)
                }
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    currentDragRect = nil
                }
                
                if selectedTool == .anchor, let rect = currentDragRect {
                     // Add Panel Command
                     if rect.width > 20 && rect.height > 20 { // Minimal size (2% of screen)
                         editorState.execute(.addPanel(rect))
                     }
                }
                
                if selectedTool == .knife {
                     // Perform split at line
                     let splitX = CoordinateConverter.normalize(point: value.location, in: size).x
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
    
    private func hitTest(_ point: NormalizedCoordinate) -> Int? {
        // Find last panel containing point (topmost)
        for (index, panel) in editorState.pageModel.panels.enumerated().reversed() {
            if point.x >= panel.minX && point.x <= panel.maxX &&
               point.y >= panel.minY && point.y <= panel.maxY {
                return index
            }
        }
        return nil
    }
}

extension View {
    func invertedMask() -> some View {
        return self // Placeholder
    }
}
