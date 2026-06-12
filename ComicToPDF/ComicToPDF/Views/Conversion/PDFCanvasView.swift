import SwiftUI
import PencilKit

/// A SwiftUI wrapper for PKCanvasView to support Pro Mode drawing
struct PDFCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var drawingData: Data
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        
        // Restore existing drawing if any
        if !drawingData.isEmpty {
            do {
                let existingDrawing = try PKDrawing(data: drawingData)
                canvasView.drawing = existingDrawing
            } catch {
                Logger.shared.log("Failed to load initial PKDrawing", category: "CanvasView", type: .warning)
            }
        }
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Sync drawing updates if needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PDFCanvasView
        
        init(_ parent: PDFCanvasView) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Save stroke changes back to the source bounds
            parent.drawingData = canvasView.drawing.dataRepresentation()
        }
    }
}
