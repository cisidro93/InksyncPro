import SwiftUI
import SwiftData
import PencilKit

/// Custom PKCanvasView subclass that forwards finger touches (taps, pans, page turns, text selection)
/// down to the underlying PDFView while allowing Apple Pencil to draw seamlessly.
final class PassthroughPKCanvasView: PKCanvasView {
    var allowFingerDrawing: Bool = false
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let view = super.hitTest(point, with: event) else { return nil }
        
        if allowFingerDrawing {
            return view
        }
        
        // If touches are present in the event:
        if let touches = event?.allTouches, !touches.isEmpty {
            let hasStylus = touches.contains { $0.type == .pencil || $0.type == .stylus }
            if hasStylus {
                return view
            } else {
                // Direct finger touches pass directly through to PDFView below
                return nil
            }
        }
        
        // When event has no touches yet (initial hit-test probe from window):
        // Return view so that Apple Pencil touch recognizers are not filtered out on probe.
        return view
    }
}

struct PageCanvasOverlay: View {
    let pdfID: UUID?
    let pageIndex: Int
    let isMarkupEnabled: Bool
    /// Passed explicitly from the parent view or defaults to AppSettingsManager.shared
    /// to avoid relying on a potentially broken @EnvironmentObject chain across UIViewRepresentable boundaries.
    var pencilOnlyDrawing: Bool = AppSettingsManager.shared.conversionSettings.pencilOnlyDrawing
    
    // ✅ Fix: Use sharedModelContainer.mainContext directly rather than @Environment(\.modelContext)
    // which silently fails when the view is not embedded in a .modelContainer() ancestor.
    private var modelContext: ModelContext {
        InksyncProApp.sharedModelContainer.mainContext
    }
    
    @State private var canvasView = PassthroughPKCanvasView()
    @State private var activeAnnotation: SDAnnotation?
    @State private var hasLoaded = false
    
    var body: some View {
        GeometryReader { geo in
            PKCanvasRepresentation(canvasView: $canvasView, isMarkupEnabled: isMarkupEnabled, pencilOnlyDrawing: pencilOnlyDrawing)
                .allowsHitTesting(isMarkupEnabled)
                .onAppear {
                    loadDrawing()
                }
                .onChange(of: pageIndex) { _, _ in
                    saveDrawing()
                    loadDrawing()
                }
                .onDisappear {
                    saveDrawing()
                }
        }
    }
    
    private func loadDrawing() {
        guard let pdfID = pdfID else { return }
        let targetID = pdfID
        let pIndex = pageIndex
        let ctx = modelContext
        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.pdfID == targetID && $0.pageIndex == pIndex && $0.kindRaw == "ink" })
        
        if let existing = try? ctx.fetch(descriptor).first {
            self.activeAnnotation = existing
            if let data = existing.drawingData, let drawing = try? PKDrawing(data: data) {
                self.canvasView.drawing = drawing
            } else {
                self.canvasView.drawing = PKDrawing()
            }
        } else {
            self.activeAnnotation = nil
            self.canvasView.drawing = PKDrawing()
        }
        hasLoaded = true
    }
    
    private func saveDrawing() {
        guard hasLoaded, let pdfID = pdfID else { return }
        let ctx = modelContext
        let currentDrawingData = canvasView.drawing.dataRepresentation()
        let drawing = canvasView.drawing
        
        // Don't save empty drawings if annotation doesn't exist
        if drawing.bounds.isEmpty && activeAnnotation == nil {
            return
        }
        
        if let annotation = activeAnnotation {
            annotation.drawingData = currentDrawingData
            annotation.modifiedAt = Date()
            try? ctx.save()
        } else {
            var dto = Annotation(
                id: UUID(),
                pdfID: pdfID,
                pageIndex: pageIndex,
                chapterTitle: nil,
                kind: .ink,
                createdAt: Date(),
                modifiedAt: Date()
            )
            dto.drawingData = currentDrawingData
            let newInk = SDAnnotation(from: dto)
            ctx.insert(newInk)
            self.activeAnnotation = newInk
            try? ctx.save()
            AnnotationStore.shared.add(dto)
        }
        
        if let annotation = activeAnnotation {
            if !drawing.bounds.isEmpty {
                Task { @MainActor in
                    if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                        if let active = self.activeAnnotation, active.drawingOCRText != ocrText {
                            active.drawingOCRText = ocrText
                            active.modifiedAt = Date()
                            try? InksyncProApp.sharedModelContainer.mainContext.save()
                            Logger.shared.log("Page ink OCR updated for page \(self.pageIndex): \(ocrText.prefix(40))...", category: "OCR", type: .success)
                            SpotlightIndexer.shared.indexAnnotation(active)
                        }
                    }
                }
            } else {
                SpotlightIndexer.shared.indexAnnotation(annotation)
            }
        }
    }
}

struct PKCanvasRepresentation: UIViewRepresentable {
    @Binding var canvasView: PassthroughPKCanvasView
    let isMarkupEnabled: Bool
    /// ✅ Fix: Passed as explicit init parameter instead of @EnvironmentObject to prevent
    /// a fatal runtime crash ("No ObservableObject of type AppSettingsManager found")
    /// when AppSettingsManager is not in the environment chain above a UIViewRepresentable.
    let pencilOnlyDrawing: Bool
    
    func makeUIView(context: Context) -> PassthroughPKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        // On iPad: use .pencilOnly so fingers navigate while Pencil draws.
        // On iPhone: use .anyInput when markup is enabled so fingers can draw/highlight.
        let pencilOnly = isPad && (pencilOnlyDrawing || prefs.applePencilAutoDraw)
        canvasView.allowFingerDrawing = isMarkupEnabled && !pencilOnly
        canvasView.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        canvasView.isUserInteractionEnabled = true
        canvasView.drawingGestureRecognizer.cancelsTouchesInView = false
        canvasView.isScrollEnabled = !pencilOnly
        canvasView.bounces = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        if pencilOnly {
            canvasView.panGestureRecognizer.isEnabled = false
        }
        
        // Configure default tool to vibrant highlighter
        if canvasView.tool is PKInkingTool || !(canvasView.tool is PKEraserTool) {
            canvasView.tool = PKInkingTool(.marker, color: UIColor.systemYellow.withAlphaComponent(0.55), width: 22)
        }
        
        // Attach Apple Pencil Interaction on iPad only
        if isPad {
            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = context.coordinator
            canvasView.addInteraction(pencilInteraction)
        }
        
        let picker = PKToolPicker()
        picker.setVisible(isMarkupEnabled, forFirstResponder: canvasView)
        picker.addObserver(canvasView)
        context.coordinator.toolPicker = picker
        context.coordinator.canvasView = canvasView
        
        if isMarkupEnabled {
            canvasView.becomeFirstResponder()
        }
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PassthroughPKCanvasView, context: Context) {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        let pencilOnly = isPad && (pencilOnlyDrawing || prefs.applePencilAutoDraw)
        uiView.allowFingerDrawing = isMarkupEnabled && !pencilOnly
        uiView.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        uiView.isUserInteractionEnabled = true
        uiView.drawingGestureRecognizer.cancelsTouchesInView = false
        uiView.isScrollEnabled = !pencilOnly
        uiView.bounces = false
        if pencilOnly {
            uiView.panGestureRecognizer.isEnabled = false
        }
        context.coordinator.canvasView = uiView
        
        if isMarkupEnabled {
            uiView.becomeFirstResponder()
            context.coordinator.toolPicker?.setVisible(true, forFirstResponder: uiView)
        } else {
            uiView.resignFirstResponder()
            context.coordinator.toolPicker?.setVisible(false, forFirstResponder: uiView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleUIView(_ uiView: PassthroughPKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker?.setVisible(false, forFirstResponder: uiView)
        coordinator.toolPicker?.removeObserver(uiView)
        uiView.resignFirstResponder()
        coordinator.toolPicker = nil
        coordinator.canvasView = nil
    }
    
    class Coordinator: NSObject, UIPencilInteractionDelegate {
        var toolPicker: PKToolPicker?
        weak var canvasView: PassthroughPKCanvasView?
        private var previousInkingTool: PKTool?
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard let canvas = canvasView else { return }
            HapticEngine.light()
            
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser:
                if canvas.tool is PKEraserTool {
                    canvas.tool = previousInkingTool ?? PKInkingTool(.pen, color: .systemOrange, width: 3)
                } else {
                    previousInkingTool = canvas.tool
                    canvas.tool = PKEraserTool(.vector)
                }
            case .switchPrevious:
                if let prev = previousInkingTool {
                    let current = canvas.tool
                    canvas.tool = prev
                    previousInkingTool = current
                }
            case .showColorPalette, .showInkAttributes:
                toolPicker?.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            case .ignore:
                break
            default:
                // Covers .showContextualPalette and .runSystemShortcut (iOS 17.5+)
                // and any future cases Apple may add.  Showing the tool picker is
                // the safest fallback for all palette-adjacent actions.
                if #available(iOS 17.5, *) {
                    toolPicker?.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                } else {
                    // Pre-iOS 17.5: no additional cases exist; default to eraser toggle.
                    if canvas.tool is PKEraserTool {
                        canvas.tool = previousInkingTool ?? PKInkingTool(.pen, color: .systemOrange, width: 3)
                    } else {
                        previousInkingTool = canvas.tool
                        canvas.tool = PKEraserTool(.vector)
                    }
                }
            }
        }
        
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard let canvas = canvasView else { return }
            if squeeze.phase == .ended {
                HapticEngine.selection()
                if let picker = toolPicker {
                    picker.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                }
            }
        }
    }
}
