import SwiftUI
import SwiftData
import PencilKit

/// Custom PKCanvasView subclass that forwards finger touches (taps, pans, page turns)
/// down to the underlying reader when drawingPolicy is `.pencilOnly`.
final class PassthroughPKCanvasView: PKCanvasView {
    var allowFingerDrawing: Bool = false
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // If finger drawing is disabled (Pencil Only mode on iPad):
        if !allowFingerDrawing {
            if let touches = event?.allTouches, !touches.isEmpty {
                let hasStylus = touches.contains { $0.type == .pencil || $0.type == .stylus }
                if !hasStylus {
                    // Finger touch: pass through to PDFView / Reader
                    return nil
                }
            }
        }
        return super.hitTest(point, with: event)
    }
}

struct PageCanvasOverlay: View {
    let pdfID: UUID?
    let pageIndex: Int
    let isMarkupEnabled: Bool
    
    @Environment(\.modelContext) private var modelContext
    @State private var canvasView = PassthroughPKCanvasView()
    @State private var activeAnnotation: SDAnnotation?
    @State private var hasLoaded = false
    
    var body: some View {
        GeometryReader { geo in
            PKCanvasRepresentation(canvasView: $canvasView, isMarkupEnabled: isMarkupEnabled)
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
        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.pdfID == targetID && $0.pageIndex == pIndex && $0.kindRaw == "ink" })
        
        if let existing = try? modelContext.fetch(descriptor).first {
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
        
        let currentDrawingData = canvasView.drawing.dataRepresentation()
        let drawing = canvasView.drawing
        
        // Don't save empty drawings if annotation doesn't exist
        if drawing.bounds.isEmpty && activeAnnotation == nil {
            return
        }
        
        if let annotation = activeAnnotation {
            annotation.drawingData = currentDrawingData
            annotation.modifiedAt = Date()
        } else {
            let newInk = SDAnnotation(
                id: UUID(),
                pdfID: pdfID.uuidString,
                pageIndex: pageIndex,
                text: nil,
                note: nil,
                isReadwiseImport: false,
                readwiseBookTitle: nil,
                readwiseAuthor: nil,
                createdAt: Date()
            )
            newInk.kindRaw = "ink"
            newInk.drawingData = currentDrawingData
            modelContext.insert(newInk)
            self.activeAnnotation = newInk
        }
        try? modelContext.save()
        
        if let annotation = activeAnnotation {
            if !drawing.bounds.isEmpty {
                Task.detached(priority: .background) {
                    if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                        await MainActor.run {
                            if let active = self.activeAnnotation, active.drawingOCRText != ocrText {
                                active.drawingOCRText = ocrText
                                active.modifiedAt = Date()
                                try? self.modelContext.save()
                                Logger.shared.log("Page ink OCR updated for page \(self.pageIndex): \(ocrText.prefix(40))...", category: "OCR", type: .success)
                                SpotlightIndexer.shared.indexAnnotation(active)
                            }
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
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    func makeUIView(context: Context) -> PassthroughPKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        // On iPad: use .pencilOnly so fingers navigate while Pencil draws.
        // On iPhone: use .anyInput when markup is enabled so fingers can draw/highlight.
        let pencilOnly = isPad && (settingsManager.conversionSettings.pencilOnlyDrawing || prefs.applePencilAutoDraw)
        canvasView.allowFingerDrawing = isMarkupEnabled && !pencilOnly
        canvasView.drawingPolicy = isMarkupEnabled ? (pencilOnly ? .pencilOnly : .anyInput) : .pencilOnly
        canvasView.isUserInteractionEnabled = isMarkupEnabled
        canvasView.drawingGestureRecognizer.cancelsTouchesInView = false
        
        // Configure default tool
        if canvasView.tool is PKInkingTool || !(canvasView.tool is PKEraserTool) {
            if prefs.applePencilDefaultTool == "highlighter" {
                canvasView.tool = PKInkingTool(.marker, color: UIColor.systemYellow.withAlphaComponent(0.5), width: 16)
            } else {
                canvasView.tool = PKInkingTool(.pen, color: UIColor.systemOrange, width: 3)
            }
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
        uiView.isUserInteractionEnabled = isMarkupEnabled
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        let pencilOnly = isPad && (settingsManager.conversionSettings.pencilOnlyDrawing || prefs.applePencilAutoDraw)
        uiView.allowFingerDrawing = isMarkupEnabled && !pencilOnly
        uiView.drawingPolicy = isMarkupEnabled ? (pencilOnly ? .pencilOnly : .anyInput) : .pencilOnly
        uiView.drawingGestureRecognizer.cancelsTouchesInView = false
        context.coordinator.canvasView = uiView
        
        if isMarkupEnabled {
            uiView.becomeFirstResponder()
            context.coordinator.toolPicker?.setVisible(true, forFirstResponder: uiView)
        } else {
            uiView.resignFirstResponder()
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
