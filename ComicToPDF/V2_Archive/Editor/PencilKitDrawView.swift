import SwiftUI
import PencilKit

/// A wrapper around `PKCanvasView` that seamlessly integrates Apple Pencil drawing into SwiftUI.
struct PencilKitDrawView: UIViewRepresentable {
    @Binding var canvas: PKCanvasView
    @State var toolPicker = PKToolPicker()
    
    func makeUIView(context: Context) -> PKCanvasView {
        // Essential configuration for an Apple Pencil optimized drawing environment
        canvas.drawingPolicy = .pencilOnly // Important: Let fingers scroll/pan, pencil draws
        canvas.isOpaque = false // Allows underlying views (like comic pages) to show through
        canvas.backgroundColor = .clear
        canvas.delegate = context.coordinator
        canvas.becomeFirstResponder()
        
        return canvas
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Determine whether to show the tool palette based on responder status.
        // It provides the user with an intuitive way to select pens, highlighters, and erasers.
        if uiView.isFirstResponder {
            toolPicker.addObserver(uiView)
            toolPicker.setVisible(true, forFirstResponder: uiView)
        } else {
            toolPicker.setVisible(false, forFirstResponder: uiView)
            toolPicker.removeObserver(uiView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilKitDrawView
        
        init(_ parent: PencilKitDrawView) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Future-proofing: We can tap into this to extract drawings,
            // push them to undo history, or persist them per-comic page.
        }
    }
}
