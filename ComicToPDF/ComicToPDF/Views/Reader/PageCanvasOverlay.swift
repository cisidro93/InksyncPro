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
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        canvasView.drawingPolicy = isMarkupEnabled ? .anyInput : .pencilOnly // When not in markup, allow pencil only or disable
        canvasView.isUserInteractionEnabled = true
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Toggle interactivity. If markup is off, maybe we only allow Apple Pencil, or completely disable touch
        // so gestures pass through to the reader.
        uiView.isUserInteractionEnabled = isMarkupEnabled
        uiView.drawingPolicy = .anyInput
    }
}
