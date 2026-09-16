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
        // Guarantee the coordinator receives updated parent bindings across SwiftUI state transitions
        context.coordinator.parent = self
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
            
            // GoodNotes-style Scribble-to-Erase
            if let lastStroke = canvasView.drawing.strokes.last {
                if let erasedDrawing = detectScribbleAndErase(in: canvasView.drawing, lastStroke: lastStroke) {
                    isSnapping = true
                    canvasView.drawing = erasedDrawing
                    isSnapping = false
                    
                    // Tactile scribble erase haptic feedback
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    parent.onSaved()
                    return
                }
            }
            
            if parent.isSmartShapesEnabled {
                if let updatedDrawing = snapLastStroke(in: canvasView.drawing) {
                    isSnapping = true
                    canvasView.drawing = updatedDrawing
                    isSnapping = false
                    
                    // Tactile shape snap haptic feedback
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            
            parent.onSaved()
        }
        
        private func snapLastStroke(in drawing: PKDrawing) -> PKDrawing? {
            guard let lastStroke = drawing.strokes.last else { return nil }
            let points = lastStroke.path.map { $0 }
            guard points.count >= 6 else { return nil }
            
            let lastPoint = points[points.count - 1]
            
            // 1. Detect if stylus held stationary at the end (pause-to-snap)
            // On iPad Pro, Apple Pencil samples at 120Hz-240Hz.
            // Check points in the final ~0.25 seconds of the stroke for low positional jitter (< 28pt).
            let pauseWindow: TimeInterval = 0.25
            let recentPoints = points.filter { $0.timeOffset >= (lastPoint.timeOffset - pauseWindow) }
            let isHeldAtEnd: Bool = {
                guard recentPoints.count >= 4 else { return false }
                var rMinX = recentPoints[0].location.x, rMaxX = recentPoints[0].location.x
                var rMinY = recentPoints[0].location.y, rMaxY = recentPoints[0].location.y
                for pt in recentPoints {
                    rMinX = min(rMinX, pt.location.x)
                    rMaxX = max(rMaxX, pt.location.x)
                    rMinY = min(rMinY, pt.location.y)
                    rMaxY = max(rMaxY, pt.location.y)
                }
                return max(rMaxX - rMinX, rMaxY - rMinY) < 28.0
            }()
            
            // If held at end, drop the stationary tail points to analyze intended geometry
            let shapePoints: [CGPoint] = (isHeldAtEnd && recentPoints.count >= 4)
                ? points.dropLast(recentPoints.count - 2).map { $0.location }
                : points.map { $0.location }
            
            guard shapePoints.count >= 4,
                  let ptStart = shapePoints.first,
                  let ptEnd = shapePoints.last else { return nil }
            
            // Total path perimeter length
            var pathLength: CGFloat = 0
            for i in 1..<shapePoints.count {
                pathLength += distance(shapePoints[i], shapePoints[i - 1])
            }
            guard pathLength > 24.0 else { return nil } // Ignore tiny tap artifacts
            
            let startEndDist = distance(ptStart, ptEnd)
            let isClosed = startEndDist < 42.0 || (startEndDist / pathLength < 0.22)
            
            var snappedPoints: [CGPoint] = []
            
            if !isClosed {
                // ── Straight Line Recognition ──
                let dx = ptEnd.x - ptStart.x
                let dy = ptEnd.y - ptStart.y
                let lineLen = sqrt(dx * dx + dy * dy)
                guard lineLen > 25.0 else { return nil }
                
                // Measure max perpendicular deviation from start-to-end chord
                var maxDev: CGFloat = 0
                for pt in shapePoints {
                    let dev = abs(dy * pt.x - dx * pt.y + ptEnd.x * ptStart.y - ptEnd.y * ptStart.x) / lineLen
                    if dev > maxDev { maxDev = dev }
                }
                
                // If maximum deviation is less than 14% of the line length, snap to a straight line
                if (maxDev / lineLen) < 0.14 || isHeldAtEnd {
                    var finalStart = ptStart
                    var finalEnd = ptEnd
                    
                    // Near-horizontal snap (within 5pt Y)
                    if abs(dy) < 8.0 {
                        let avgY = (ptStart.y + ptEnd.y) / 2.0
                        finalStart.y = avgY
                        finalEnd.y = avgY
                    }
                    // Near-vertical snap (within 5pt X)
                    else if abs(dx) < 8.0 {
                        let avgX = (ptStart.x + ptEnd.x) / 2.0
                        finalStart.x = avgX
                        finalEnd.x = avgX
                    }
                    
                    snappedPoints = [finalStart, finalEnd]
                }
            } else {
                // ── Closed Shapes: Circle, Ellipse, Rectangle, Triangle ──
                var minX = shapePoints[0].x, maxX = shapePoints[0].x
                var minY = shapePoints[0].y, maxY = shapePoints[0].y
                for pt in shapePoints {
                    minX = min(minX, pt.x); maxX = max(maxX, pt.x)
                    minY = min(minY, pt.y); maxY = max(maxY, pt.y)
                }
                
                let width = maxX - minX
                let height = maxY - minY
                guard width > 18.0 && height > 18.0 else { return nil }
                
                let center = CGPoint(x: (minX + maxX) / 2.0, y: (minY + maxY) / 2.0)
                let rx = max(width / 2.0, 1.0)
                let ry = max(height / 2.0, 1.0)
                
                // Ellipse/Circle fit error (RMS deviation from algebraic unit distance)
                let ellipseError = sqrt(shapePoints.map { pt in
                    let norm = pow((pt.x - center.x) / rx, 2) + pow((pt.y - center.y) / ry, 2)
                    return pow(norm - 1.0, 2)
                }.reduce(0, +) / CGFloat(shapePoints.count))
                
                if ellipseError < 0.32 {
                    // Circle vs Ellipse
                    let isNearCircle = abs(width - height) / max(width, height) < 0.18
                    let radiusX = isNearCircle ? (rx + ry) / 2.0 : rx
                    let radiusY = isNearCircle ? (rx + ry) / 2.0 : ry
                    
                    let steps = 48
                    for i in 0...steps {
                        let angle = (CGFloat(i) / CGFloat(steps)) * 2.0 * .pi
                        let x = center.x + radiusX * cos(angle)
                        let y = center.y + radiusY * sin(angle)
                        snappedPoints.append(CGPoint(x: x, y: y))
                    }
                } else {
                    // Polygon simplification (Douglas-Peucker approximation)
                    let corners = simplifyPolygon(shapePoints, epsilon: max(width, height) * 0.10)
                    
                    if corners.count == 3 {
                        // Triangle
                        snappedPoints = [corners[0], corners[1], corners[2], corners[0]]
                    } else {
                        // Rectangle / Square
                        let isNearSquare = abs(width - height) / max(width, height) < 0.12
                        let sWidth = isNearSquare ? (width + height) / 2.0 : width
                        let sHeight = isNearSquare ? (width + height) / 2.0 : height
                        let rMinX = center.x - sWidth / 2.0
                        let rMaxX = center.x + sWidth / 2.0
                        let rMinY = center.y - sHeight / 2.0
                        let rMaxY = center.y + sHeight / 2.0
                        
                        let tl = CGPoint(x: rMinX, y: rMinY)
                        let tr = CGPoint(x: rMaxX, y: rMinY)
                        let br = CGPoint(x: rMaxX, y: rMaxY)
                        let bl = CGPoint(x: rMinX, y: rMaxY)
                        snappedPoints = [tl, tr, br, bl, tl]
                    }
                }
            }
            
            guard !snappedPoints.isEmpty else { return nil }
            
            // 3. Generate smooth, interpolated PKStroke points with matching ink properties
            var newStrokePoints: [PKStrokePoint] = []
            let totalNew = snappedPoints.count
            let lastOrigPoint = points.last ?? points[0]
            
            for (idx, pt) in snappedPoints.enumerated() {
                let frac = CGFloat(idx) / CGFloat(max(totalNew - 1, 1))
                let origIdx = min(Int(frac * CGFloat(points.count - 1)), points.count - 1)
                let origPoint = points[origIdx]
                
                let newPt = PKStrokePoint(
                    location: pt,
                    timeOffset: Double(frac) * 0.08,
                    size: origPoint.size,
                    opacity: origPoint.opacity,
                    force: max(origPoint.force, 0.5),
                    azimuth: origPoint.azimuth,
                    altitude: origPoint.altitude
                )
                newStrokePoints.append(newPt)
            }
            
            let strokePath = PKStrokePath(controlPoints: newStrokePoints, creationDate: lastStroke.path.creationDate)
            let snappedStroke = PKStroke(ink: lastStroke.ink, path: strokePath)
            
            var newStrokes = drawing.strokes
            newStrokes.removeLast()
            newStrokes.append(snappedStroke)
            
            return PKDrawing(strokes: newStrokes)
        }
        
        // MARK: - Douglas-Peucker Corner Detection for Triangles & Polygons
        private func simplifyPolygon(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
            guard points.count >= 3 else { return points }
            
            var dmax: CGFloat = 0
            var index = 0
            let end = points.count - 1
            
            for i in 1..<end {
                let d = perpendicularDistance(point: points[i], lineStart: points[0], lineEnd: points[end])
                if d > dmax {
                    index = i
                    dmax = d
                }
            }
            
            if dmax > epsilon {
                let rec1 = simplifyPolygon(Array(points[0...index]), epsilon: epsilon)
                let rec2 = simplifyPolygon(Array(points[index...end]), epsilon: epsilon)
                return Array(rec1.dropLast()) + rec2
            } else {
                return [points[0], points[end]]
            }
        }
        
        private func perpendicularDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
            let dx = lineEnd.x - lineStart.x
            let dy = lineEnd.y - lineStart.y
            let len = sqrt(dx * dx + dy * dy)
            guard len > 0.001 else { return distance(point, lineStart) }
            return abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x) / len
        }
        
        private func detectScribbleAndErase(in drawing: PKDrawing, lastStroke: PKStroke) -> PKDrawing? {
            let points = lastStroke.path.map { $0 }
            guard points.count >= 8 else { return nil }
            
            // Analyze direction changes (horizontal flips)
            var directionChangesCount = 0
            var lastDX: CGFloat = 0
            
            for i in 1..<points.count {
                let dx = points[i].location.x - points[i - 1].location.x
                if i > 1 {
                    if (dx > 0.5 && lastDX < -0.5) || (dx < -0.5 && lastDX > 0.5) {
                        directionChangesCount += 1
                    }
                }
                if abs(dx) > 0.5 {
                    lastDX = dx
                }
            }
            
            // Require at least 4 horizontal shifts to recognize as a scribble
            guard directionChangesCount >= 4 else { return nil }
            
            let scribbleBounds = lastStroke.renderBounds
            guard scribbleBounds.width < 180 && scribbleBounds.height < 180 else { return nil }
            
            var remainingStrokes = drawing.strokes
            if !remainingStrokes.isEmpty {
                remainingStrokes.removeLast()
            }
            
            let originalCount = remainingStrokes.count
            remainingStrokes = remainingStrokes.filter { stroke in
                !stroke.renderBounds.intersects(scribbleBounds)
            }
            
            if remainingStrokes.count < originalCount {
                return PKDrawing(strokes: remainingStrokes)
            }
            
            return nil
        }
        
        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
        }
    }
}
