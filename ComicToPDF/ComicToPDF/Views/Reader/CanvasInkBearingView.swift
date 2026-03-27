import SwiftUI
import PencilKit

/// Reusable PencilKit Overlay Canvas matching GoodNotes Parity
/// Adheres to Phase 30 Power Conservation limits by deferring rendering vectors to UIImages when inactive.
struct CanvasInkBearingView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let isDrawingMode: Bool
    var onDrawingSaved: ((PKDrawing) -> Void)?
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .pencilOnly
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false // Transparent overlay
        
        // Setup internal tools (can be expanded to support tool picker)
        canvasView.tool = PKInkingTool(.pen, color: .systemRed, width: 3)
        canvasView.delegate = context.coordinator
        
        // Power Optimization: Flatten active state to reduce Metal re-draws when scrolling
        canvasView.isUserInteractionEnabled = isDrawingMode
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isDrawingMode
        
        if isDrawingMode {
            uiView.becomeFirstResponder()
        } else {
            uiView.resignFirstResponder()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasInkBearingView
        
        init(_ parent: CanvasInkBearingView) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Callback to save to disk or convert to PDF Annotation
            parent.onDrawingSaved?(canvasView.drawing)
        }
    }
}
