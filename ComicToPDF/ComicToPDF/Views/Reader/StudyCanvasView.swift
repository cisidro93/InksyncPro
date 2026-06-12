import SwiftUI
import PencilKit

struct StudyCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @State var toolPicker = PKToolPicker()
    
    // An action triggered when drawing changes, useful for debounce saving
    var onSaved: () -> Void
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        // Set to .anyInput so it works on simulators and with fingers,
        // we can add a toggle later for pencil-only mode.
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        
        // Setup tool picker
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        
        // We delay becomeFirstResponder to ensure the view is in the hierarchy
        DispatchQueue.main.async {
            canvasView.becomeFirstResponder()
        }
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // No-op for now. Updates are handled by the view state itself.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: StudyCanvasView
        
        init(_ parent: StudyCanvasView) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.onSaved()
        }
    }
}
