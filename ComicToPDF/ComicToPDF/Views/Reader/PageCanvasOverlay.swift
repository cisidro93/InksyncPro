import SwiftUI
import SwiftData
import PencilKit

struct PageCanvasOverlay: View {
    let pdfID: UUID?
    let pageIndex: Int
    let isMarkupEnabled: Bool
    
    @Environment(\.modelContext) private var modelContext
    @State private var canvasView = PKCanvasView()
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
    @Binding var canvasView: PKCanvasView
    let isMarkupEnabled: Bool
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        
        let prefs = EBookPreferences.shared
        // Default to pencilOnly so finger gestures smoothly scroll and turn pages
        let pencilOnly = settingsManager.conversionSettings.pencilOnlyDrawing || prefs.applePencilAutoDraw
        canvasView.drawingPolicy = isMarkupEnabled ? (pencilOnly ? .pencilOnly : .anyInput) : .pencilOnly
        canvasView.isUserInteractionEnabled = isMarkupEnabled
        
        // Configure default tool
        if canvasView.tool is PKInkingTool || !(canvasView.tool is PKEraserTool) {
            if prefs.applePencilDefaultTool == "highlighter" {
                canvasView.tool = PKInkingTool(.marker, color: UIColor.systemYellow.withAlphaComponent(0.5), width: 16)
            } else {
                canvasView.tool = PKInkingTool(.pen, color: UIColor.systemOrange, width: 3)
            }
        }
        
        // Attach Apple Pencil Double-Tap / Squeeze Interaction
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)
        
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
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isMarkupEnabled
        let prefs = EBookPreferences.shared
        let pencilOnly = settingsManager.conversionSettings.pencilOnlyDrawing || prefs.applePencilAutoDraw
        uiView.drawingPolicy = isMarkupEnabled ? (pencilOnly ? .pencilOnly : .anyInput) : .pencilOnly
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
    
    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker?.setVisible(false, forFirstResponder: uiView)
        coordinator.toolPicker?.removeObserver(uiView)
        uiView.resignFirstResponder()
        coordinator.toolPicker = nil
        coordinator.canvasView = nil
    }
    
    class Coordinator: NSObject, UIPencilInteractionDelegate {
        var toolPicker: PKToolPicker?
        weak var canvasView: PKCanvasView?
        private var previousInkingTool: PKTool?
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard let canvas = canvasView else { return }
            HapticEngine.light()
            
            if canvas.tool is PKEraserTool {
                // Switch back to previous tool or default highlighter
                if let prev = previousInkingTool {
                    canvas.tool = prev
                } else {
                    canvas.tool = PKInkingTool(.marker, color: UIColor.systemYellow.withAlphaComponent(0.5), width: 16)
                }
            } else {
                // Save current tool and switch to eraser
                previousInkingTool = canvas.tool
                canvas.tool = PKEraserTool(.vector)
            }
        }
    }
}
