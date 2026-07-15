import SwiftUI
import PencilKit
import UIKit

struct StudyCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var isSmartShapesEnabled: Bool
    @State var toolPicker = PKToolPicker()
    
    // An action triggered when drawing changes, useful for debounce saving
    var onSaved: () -> Void
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        
        // Hide the native tool picker since we have our custom integrated toolbar
        toolPicker.setVisible(false, forFirstResponder: canvasView)
        toolPicker.removeObserver(canvasView)
        
        DispatchQueue.main.async {
            canvasView.becomeFirstResponder()
        }
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Updates are handled by the view state itself.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: StudyCanvasView
        private var isSnapping = false
        
        init(_ parent: StudyCanvasView) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isSnapping else { return }
            
            if parent.isSmartShapesEnabled {
                if let updatedDrawing = snapLastStroke(in: canvasView.drawing) {
                    isSnapping = true
                    canvasView.drawing = updatedDrawing
                    isSnapping = false
                    
                    // Trigger a tactile shape snap haptic feedback
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            
            parent.onSaved()
        }
        
        private func snapLastStroke(in drawing: PKDrawing) -> PKDrawing? {
            guard let lastStroke = drawing.strokes.last else { return nil }
            let points = lastStroke.path.map { $0 }
            guard points.count >= 12 else { return nil }
            
            // 1. Detect if held at the end (stationary last 12 points)
            let lastPoints = points.suffix(12)
            let firstOfLast = lastPoints.first!
            let lastOfLast = lastPoints.last!
            
            var minX = firstOfLast.location.x
            var maxX = firstOfLast.location.x
            var minY = firstOfLast.location.y
            var maxY = firstOfLast.location.y
            for pt in lastPoints {
                minX = min(minX, pt.location.x)
                maxX = max(maxX, pt.location.x)
                minY = min(minY, pt.location.y)
                maxY = max(maxY, pt.location.y)
            }
            
            let spread = max(maxX - minX, maxY - minY)
            let timeSpan = lastOfLast.timeOffset - firstOfLast.timeOffset
            
            // If the user held the pencil stationary (spread < 8 points) for at least 0.4 seconds
            guard spread < 8.0 && timeSpan > 0.4 else { return nil }
            
            // 2. Extract shape points (exclude the holding points at the end)
            let shapePoints = points.dropLast(10).map { $0.location }
            guard shapePoints.count >= 8 else { return nil }
            
            let ptStart = shapePoints.first!
            let ptEnd = shapePoints.last!
            
            // Check if shape is closed (start and end points are near each other)
            let closedThreshold: CGFloat = 35.0
            let isClosed = distance(ptStart, ptEnd) < closedThreshold
            
            var snappedPoints: [CGPoint] = []
            
            if isClosed {
                // Try Circle / Ellipse
                let sumX = shapePoints.reduce(0) { $0 + $1.x }
                let sumY = shapePoints.reduce(0) { $0 + $1.y }
                let centroid = CGPoint(x: sumX / CGFloat(shapePoints.count), y: sumY / CGFloat(shapePoints.count))
                
                let radii = shapePoints.map { distance($0, centroid) }
                let avgRadius = radii.reduce(0, +) / CGFloat(radii.count)
                
                let variance = radii.reduce(0) { $0 + pow($1 - avgRadius, 2) } / CGFloat(radii.count)
                let stdDev = sqrt(variance)
                
                if stdDev / avgRadius < 0.12 {
                    // Generate perfect circle points
                    let steps = 40
                    for i in 0...steps {
                        let angle = (CGFloat(i) / CGFloat(steps)) * 2.0 * .pi
                        let x = centroid.x + avgRadius * cos(angle)
                        let y = centroid.y + avgRadius * sin(angle)
                        snappedPoints.append(CGPoint(x: x, y: y))
                    }
                } else {
                    // Try Rectangle
                    var sMinX = shapePoints[0].x
                    var sMaxX = shapePoints[0].x
                    var sMinY = shapePoints[0].y
                    var sMaxY = shapePoints[0].y
                    for pt in shapePoints {
                        sMinX = min(sMinX, pt.x)
                        sMaxX = max(sMaxX, pt.x)
                        sMinY = min(sMinY, pt.y)
                        sMaxY = max(sMaxY, pt.y)
                    }
                    
                    let tl = CGPoint(x: sMinX, y: sMinY)
                    let tr = CGPoint(x: sMaxX, y: sMinY)
                    let br = CGPoint(x: sMaxX, y: sMaxY)
                    let bl = CGPoint(x: sMinX, y: sMaxY)
                    
                    snappedPoints = [tl, tr, br, bl, tl]
                }
            } else {
                // Try straight line
                snappedPoints = [ptStart, ptEnd]
            }
            
            guard !snappedPoints.isEmpty else { return nil }
            
            // 3. Create the new snapped PKStroke
            var newStrokePoints: [PKStrokePoint] = []
            let totalNewPoints = snappedPoints.count
            
            for (idx, pt) in snappedPoints.enumerated() {
                let progress = CGFloat(idx) / CGFloat(totalNewPoints - 1)
                let origIdx = min(Int(progress * CGFloat(points.count - 1)), points.count - 1)
                let origPoint = points[origIdx]
                
                let newPt = PKStrokePoint(
                    location: pt,
                    timeOffset: Double(progress) * 0.1,
                    size: origPoint.size,
                    opacity: origPoint.opacity,
                    force: origPoint.force,
                    azimuth: origPoint.azimuth,
                    altitude: origPoint.altitude
                )
                newStrokePoints.append(newPt)
            }
            
            let strokePath = PKStrokePath(controlPoints: newStrokePoints, creationDate: Date())
            let snappedStroke = PKStroke(ink: lastStroke.ink, path: strokePath)
            
            var newStrokes = drawing.strokes
            newStrokes.removeLast()
            newStrokes.append(snappedStroke)
            
            return PKDrawing(strokes: newStrokes)
        }
        
        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
        }
    }
}
