import SwiftUI
import PencilKit

/// Reusable PencilKit Overlay Canvas matching GoodNotes Parity
/// Phase 4E-1: Upgraded with PKToolPicker so users get the native tool palette
/// (pen, pencil, marker, eraser, lasso, ruler) above the keyboard.
struct CanvasInkBearingView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let isDrawingMode: Bool
    var onDrawingSaved: ((PKDrawing) -> Void)?

    func makeUIView(context: Context) -> PKCanvasView {
        // Phase 4E-1: allow finger drawing so the tool picker's finger option works
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false

        // Wire up delegate for save callbacks
        canvasView.delegate = context.coordinator

        // Phase 4E-1: attach PKToolPicker to this canvas (no window reference needed on iOS 14+)
        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvasView)
        picker.addObserver(canvasView)
        context.coordinator.toolPicker = picker

        // Power Optimization: disable interaction when not in drawing mode
        canvasView.isUserInteractionEnabled = isDrawingMode

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isDrawingMode

        if isDrawingMode {
            uiView.becomeFirstResponder()
            // Make the tool picker visible whenever the canvas becomes active
            context.coordinator.toolPicker?.setVisible(true, forFirstResponder: uiView)
        } else {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasInkBearingView
        /// Retained here so ARC doesn't deallocate the picker while the canvas is live.
        var toolPicker: PKToolPicker?

        init(_ parent: CanvasInkBearingView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.onDrawingSaved?(canvasView.drawing)
        }
    }
}
