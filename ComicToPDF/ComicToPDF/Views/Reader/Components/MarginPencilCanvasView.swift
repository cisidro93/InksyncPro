import SwiftUI
import PencilKit
import SwiftData

/// PencilKit Freehand Margin Canvas View
/// Allows users to write hand-written Apple Pencil notes or margin drawings
/// directly on side margins of EPUBs and PDFs.
struct MarginPencilCanvasView: View {
    let pdfID: UUID
    let pageIndex: Int
    let chapterTitle: String?
    
    @Environment(\.modelContext) private var modelContext
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    @State private var isPencilOnly = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            PencilKitRepresentable(canvasView: $canvasView, toolPicker: $toolPicker, isPencilOnly: isPencilOnly)
                .edgesIgnoringSafeArea(.all)
            
            // Floating Canvas Toolbar Toggle
            HStack(spacing: 8) {
                Button(action: {
                    saveInkDrawing()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .bold))
                        Text("Save Ink")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                
                Button(action: {
                    canvasView.drawing = PKDrawing()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Circle())
                }
            }
            .padding(12)
        }
        .onAppear {
            loadExistingInkDrawing()
        }
    }
    
    private func loadExistingInkDrawing() {
        let annotations = AnnotationStore.shared.annotations(for: pdfID)
            .filter { $0.pageIndex == pageIndex && $0.kind == .ink }
        if let firstInk = annotations.first, let rawData = firstInk.drawingData {
            if let drawing = try? PKDrawing(data: rawData) {
                canvasView.drawing = drawing
            }
        }
    }
    
    private func saveInkDrawing() {
        let drawing = canvasView.drawing
        guard !drawing.bounds.isEmpty else { return }
        let inkData = drawing.dataRepresentation()
        
        let annotation = Annotation(
            pdfID: pdfID,
            pageIndex: pageIndex,
            chapterTitle: chapterTitle,
            kind: .ink,
            createdAt: Date(),
            modifiedAt: Date(),
            colorHex: "#FF9500",
            selectedText: "Apple Pencil Margin Note (Page \(pageIndex + 1))",
            drawingData: inkData
        )
        
        AnnotationStore.shared.add(annotation)
        let sdAnnotation = SDAnnotation(from: annotation)
        modelContext.insert(sdAnnotation)
        try? modelContext.save()
    }
}

struct PencilKitRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    var isPencilOnly: Bool
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = isPencilOnly ? .pencilOnly : .anyInput
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.drawingPolicy = isPencilOnly ? .pencilOnly : .anyInput
    }
}
