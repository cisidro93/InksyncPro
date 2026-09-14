import UIKit
import PDFKit
import PencilKit

// MARK: - ColoringPageOverlayView

/// Dual-layer container for PDFKit page tiles enabling professional digital coloring.
/// - Bottom Layer: `PassthroughPKCanvasView` (captures Apple Pencil strokes at 120Hz ProMotion).
/// - Top Layer: `lineartView` (displays transparent lineart mask where paper is transparent
///   and contours are opaque black; non-interactive so touches pass directly to the canvas).
///
/// When `isColoringMode` is active:
/// Colors drawn on the canvas flow seamlessly underneath the lineart mask, keeping black
/// contours crisp, untouched, and on top at all times.
@MainActor
final class ColoringPageOverlayView: UIView {

    let canvasView: PassthroughPKCanvasView
    let lineartView: UIImageView

    var isColoringMode: Bool = false {
        didSet {
            lineartView.isHidden = !isColoringMode || lineartView.image == nil
        }
    }

    var pageIndex: Int {
        get { canvasView.pageIndex }
        set { canvasView.pageIndex = newValue }
    }

    weak var associatedPage: PDFPage? {
        get { canvasView.associatedPage }
        set { canvasView.associatedPage = newValue }
    }

    init(frame: CGRect, canvasView: PassthroughPKCanvasView) {
        self.canvasView = canvasView
        self.lineartView = UIImageView(frame: frame)
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 1. Configure Canvas (Bottom Layer)
        canvasView.frame = bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(canvasView)

        // 2. Configure Lineart Overlay (Top Layer)
        lineartView.frame = bounds
        lineartView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lineartView.contentMode = .scaleToFill
        lineartView.clipsToBounds = true
        lineartView.isUserInteractionEnabled = false // Zero gesture blocking
        lineartView.isHidden = true
        addSubview(lineartView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sets the extracted transparent lineart mask and updates visibility
    func setLineartMask(_ image: UIImage?) {
        lineartView.image = image
        lineartView.isHidden = !isColoringMode || image == nil
    }

    // MARK: - Hit Testing Forwarding

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Forward hit testing directly to canvasView so its passthrough logic
        // handles palm rejection, finger panning, and Pencil stroke capture.
        return canvasView.hitTest(point, with: event)
    }
}
