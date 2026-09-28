import SwiftUI
import SwiftData
import PencilKit
import PDFKit

/// Custom PKCanvasView subclass that forwards finger touches (taps, pans, page turns, text selection)
/// down to the underlying PDFView while allowing Apple Pencil to draw seamlessly.
final class PassthroughPKCanvasView: PKCanvasView {
    var allowFingerDrawing: Bool = false
    var isMarkupActive: Bool = false
    var pageIndex: Int = 0
    weak var associatedPage: PDFPage? = nil
    
    // MARK: - Digital Coloring Studio Lineart Overlay
    private let lineartView = UIImageView()

    var isColoringMode: Bool = false {
        didSet {
            lineartView.isHidden = !isColoringMode || lineartView.image == nil
        }
    }

    private func setupLineartViewIfNeeded() {
        if lineartView.superview == nil {
            lineartView.frame = bounds
            lineartView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            lineartView.contentMode = .scaleToFill
            lineartView.clipsToBounds = true
            lineartView.isUserInteractionEnabled = false // Passes all touches down to canvas
            lineartView.layer.zPosition = 999 // Floats over canvas strokes
            lineartView.isHidden = !isColoringMode || lineartView.image == nil
            addSubview(lineartView)
        }
    }

    func setLineartMask(_ image: UIImage?) {
        lineartView.image = image
        setupLineartViewIfNeeded()
        lineartView.isHidden = !isColoringMode || image == nil
        bringSubviewToFront(lineartView)
    }

    func updateLineartVisibility() {
        lineartView.isHidden = !isColoringMode || lineartView.image == nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        lineartView.frame = bounds
        if lineartView.superview != nil {
            bringSubviewToFront(lineartView)
        }
    }

    private let internalUndoManager = UndoManager()
    override var undoManager: UndoManager? {
        return internalUndoManager
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        setupMultiTouchGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        overrideUserInterfaceStyle = .light
        setupMultiTouchGestures()
    }

    private let hoverReticleView: UIView = {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.layer.borderWidth = 1.2
        v.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        v.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        v.alpha = 0
        v.layer.zPosition = 1000
        return v
    }()

    private func setupHoverReticle() {
        if hoverReticleView.superview == nil {
            addSubview(hoverReticleView)
        }
    }

    @MainActor @objc private func handlePencilHover(_ gesture: UIHoverGestureRecognizer) {
        guard isMarkupActive && isInkLayerVisible else {
            hoverReticleView.alpha = 0
            return
        }

        switch gesture.state {
        case .began, .changed:
            let loc = gesture.location(in: self)
            let toolWidth: CGFloat
            let toolColor: UIColor

            if let inking = self.tool as? PKInkingTool {
                toolWidth = max(6.0, inking.width)
                toolColor = inking.color
            } else if self.tool is PKEraserTool {
                toolWidth = 20.0
                toolColor = .systemGray
            } else {
                toolWidth = 8.0
                toolColor = .systemOrange
            }

            hoverReticleView.bounds = CGRect(x: 0, y: 0, width: toolWidth, height: toolWidth)
            hoverReticleView.layer.cornerRadius = toolWidth / 2.0
            hoverReticleView.layer.borderColor = toolColor.withAlphaComponent(0.85).cgColor
            hoverReticleView.backgroundColor = toolColor.withAlphaComponent(0.20)
            hoverReticleView.center = loc

            if hoverReticleView.alpha < 0.9 {
                UIView.animate(withDuration: 0.12) {
                    self.hoverReticleView.alpha = 1.0
                }
            }
        case .ended, .cancelled:
            UIView.animate(withDuration: 0.15) {
                self.hoverReticleView.alpha = 0
            }
        default:
            break
        }
    }

    private func setupMultiTouchGestures() {
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        threeFingerTap.cancelsTouchesInView = true
        addGestureRecognizer(threeFingerTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.cancelsTouchesInView = true
        addGestureRecognizer(twoFingerTap)

        // Apple Pencil Hover (Pillar 5): Visual reticle tracks pencil tip on iPad Pro M2/M4
        let hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover(_:)))
        hoverRecognizer.cancelsTouchesInView = false
        addGestureRecognizer(hoverRecognizer)
        setupHoverReticle()
    }

    @MainActor @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if self.undoManager?.canUndo == true {
            self.undoManager?.undo()
            HapticEngine.medium()
            NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Undo"])
        } else {
            HapticEngine.light()
            NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Nothing to Undo"])
        }
    }

    @MainActor @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if self.undoManager?.canRedo == true {
            self.undoManager?.redo()
            HapticEngine.medium()
            NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Redo"])
        } else {
            HapticEngine.light()
            NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.ShowToast"), object: nil, userInfo: ["message": "Nothing to Redo"])
        }
    }
    
    var isInkLayerVisible: Bool = true {
        didSet {
            alpha = isInkLayerVisible ? 1.0 : 0.0
            isUserInteractionEnabled = isInkLayerVisible && isMarkupActive
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isMarkupActive else { return nil }
        guard isInkLayerVisible else { return nil }
        guard bounds.contains(point) else { return nil }

        // Top navigation corridor: Never capture touches in the top safe area / header zone (top 54pt of window).
        // This ensures tapping near the top edge always invokes the navigation chrome / Back button
        // without drawing stray ink marks on the document!
        if let window = self.window {
            let windowPoint = self.convert(point, to: window)
            let topSafeLimit = max(54.0, window.safeAreaInsets.top + 44.0)
            if windowPoint.y < topSafeLimit {
                return nil
            }
        } else if point.y < 54.0 {
            return nil
        }
        
        let currentMode = InksyncInkingState.shared.activeToolMode
        // When in highlight glide or read mode, touches pass down to PDFView for fluid text selection & reading
        if currentMode == .textHighlight || currentMode == .read {
            return nil
        }

        let hasPencilTouch = event?.allTouches?.contains(where: { $0.type == .pencil }) ?? false

        // ── Smart Navigation & Page-Turn Gutters (Zero-Stray-Ink Defense) ──
        // If the touch is from a finger (not Apple Pencil):
        if !hasPencilTouch {
            // 1. Smart Tiers Mode: finger taps are strictly reserved for advancing tiers
            if EBookPreferences.shared.isPDFSmartTiersActive {
                return nil
            }

            // 2. Left and Right Page-Turn Gutters:
            // Synchronized with user's configured tapZoneStyle (classic: 30%/70%, wide: 20%/80%, etc.).
            // Finger touches in margins are reserved for turning pages without leaving stray ink dots.
            // Returning nil passes the touch through to PDFView / ReaderView gesture recognizers.
            let windowWidth = self.window?.bounds.width ?? bounds.width
            let pointXInWindow = self.window != nil ? self.convert(point, to: self.window).x : point.x
            let zones = EBookPreferences.shared.tapZoneStyle.zones
            let leftEdge = windowWidth * zones.leftEdge
            let rightEdge = windowWidth * zones.rightEdge
            if pointXInWindow < leftEdge || pointXInWindow > rightEdge {
                return nil
            }
        }

        // When finger drawing is disabled (pencil-only mode / reading mode), the canvas must strictly ONLY capture
        // confirmed Apple Pencil touches. Any direct finger touch, or ambiguous event without a pencil touch,
        // MUST pass through (return nil) so document navigation, tapping to toggle UI chrome, and reading work 100% cleanly!
        if !allowFingerDrawing && currentMode != .eraser {
            if !hasPencilTouch {
                return nil
            }
        }

        // Bottom pen dock corridor: When drawing or inking near the bottom 140pt of the window,
        // automatically collapse the floating pen dock to its minimal pill so it never obscures annotations!
        if let window = self.window {
            let windowPoint = self.convert(point, to: window)
            if windowPoint.y > window.bounds.height - 140 {
                if !InksyncInkingState.shared.isDockMinimized {
                    InksyncInkingState.shared.triggerDockAutoDodge()
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncDodgePenDock"), object: nil)
                }
            }
        }

        // In write, eraser, or coloring mode, capture touch directly for PKCanvasView
        if let hit = super.hitTest(point, with: event) {
            return hit
        }
        return self
    }
}

struct PageCanvasOverlay: View {
    let pdfID: UUID?
    let pageIndex: Int
    let isMarkupEnabled: Bool
    /// Passed explicitly from the parent view or defaults to AppSettingsManager.shared
    /// to avoid relying on a potentially broken @EnvironmentObject chain across UIViewRepresentable boundaries.
    var pencilOnlyDrawing: Bool = AppSettingsManager.shared.conversionSettings.pencilOnlyDrawing
    
    // ✅ Fix: Use sharedModelContainer.mainContext directly rather than @Environment(\.modelContext)
    // which silently fails when the view is not embedded in a .modelContainer() ancestor.
    private var modelContext: ModelContext {
        InksyncProApp.sharedModelContainer.mainContext
    }
    
    @State private var canvasView = PassthroughPKCanvasView()
    @State private var activeAnnotation: SDAnnotation?
    @State private var hasLoaded = false
    
    var body: some View {
        GeometryReader { geo in
            PKCanvasRepresentation(canvasView: $canvasView, isMarkupEnabled: isMarkupEnabled, pencilOnlyDrawing: pencilOnlyDrawing)
                .allowsHitTesting(isMarkupEnabled)
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
        let ctx = modelContext
        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate { $0.pdfID == targetID && $0.pageIndex == pIndex && $0.kindRaw == "ink" })
        
        if let existing = try? ctx.fetch(descriptor).first {
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
        let ctx = modelContext
        let currentDrawingData = canvasView.drawing.dataRepresentation()
        let drawing = canvasView.drawing
        
        // Don't save empty drawings if annotation doesn't exist
        if drawing.bounds.isEmpty && activeAnnotation == nil {
            return
        }
        
        if let annotation = activeAnnotation {
            annotation.drawingData = currentDrawingData
            annotation.modifiedAt = Date()
            try? ctx.save()
        } else {
            var dto = Annotation(
                id: UUID(),
                pdfID: pdfID,
                pageIndex: pageIndex,
                chapterTitle: nil,
                kind: .ink,
                createdAt: Date(),
                modifiedAt: Date()
            )
            dto.drawingData = currentDrawingData
            let newInk = SDAnnotation(from: dto)
            ctx.insert(newInk)
            self.activeAnnotation = newInk
            try? ctx.save()
            AnnotationStore.shared.add(dto)
        }
        
        if let annotation = activeAnnotation {
            if !drawing.bounds.isEmpty {
                Task { @MainActor in
                    if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                        if let active = self.activeAnnotation, active.drawingOCRText != ocrText {
                            active.drawingOCRText = ocrText
                            active.modifiedAt = Date()
                            try? InksyncProApp.sharedModelContainer.mainContext.save()
                            Logger.shared.log("Page ink OCR updated for page \(self.pageIndex): \(ocrText.prefix(40))...", category: "OCR", type: .success)
                            SpotlightIndexer.shared.indexAnnotation(active)
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
    @Binding var canvasView: PassthroughPKCanvasView
    let isMarkupEnabled: Bool
    /// ✅ Fix: Passed as explicit init parameter instead of @EnvironmentObject to prevent
    /// a fatal runtime crash ("No ObservableObject of type AppSettingsManager found")
    /// when AppSettingsManager is not in the environment chain above a UIViewRepresentable.
    let pencilOnlyDrawing: Bool
    
    func makeUIView(context: Context) -> PassthroughPKCanvasView {
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        // On iPad: use .pencilOnly so fingers navigate while Pencil draws.
        // On iPhone: use .anyInput when markup is enabled so fingers can draw/highlight.
        let pencilOnly = isPad && (pencilOnlyDrawing || prefs.applePencilAutoDraw)
        canvasView.isMarkupActive = isMarkupEnabled
        canvasView.allowFingerDrawing = isMarkupEnabled && !pencilOnly
        canvasView.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        canvasView.isUserInteractionEnabled = isMarkupEnabled
        canvasView.drawingGestureRecognizer.cancelsTouchesInView = false
        canvasView.isScrollEnabled = !pencilOnly
        canvasView.bounces = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        if pencilOnly {
            canvasView.panGestureRecognizer.isEnabled = false
        }
        
        // Configure default tool to vibrant highlighter or fine pen based on user preference
        let highlightColor = prefs.defaultHighlightColor.directHighlightUIColor
        let defaultHighlighter = PKInkingTool(.marker, color: highlightColor, width: 22)
        let defaultPen = PKInkingTool(.pen, color: .systemOrange, width: 3)
        let preferredTool = (prefs.applePencilDefaultTool == "pen") ? defaultPen : defaultHighlighter
        
        if canvasView.tool is PKInkingTool || !(canvasView.tool is PKEraserTool) {
            canvasView.tool = preferredTool
        }
        
        // Attach Apple Pencil Interaction on iPad only
        if isPad {
            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = context.coordinator
            canvasView.addInteraction(pencilInteraction)
        }
        
        canvasView.delegate = context.coordinator
        
        let picker = PKToolPicker()
        picker.setVisible(isMarkupEnabled, forFirstResponder: canvasView)
        picker.selectedTool = preferredTool
        picker.addObserver(canvasView)
        context.coordinator.toolPicker = picker
        context.coordinator.canvasView = canvasView
        
        if isMarkupEnabled {
            DispatchQueue.main.async {
                if canvasView.window != nil {
                    canvasView.becomeFirstResponder()
                    picker.setVisible(true, forFirstResponder: canvasView)
                }
            }
        }
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PassthroughPKCanvasView, context: Context) {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        let inkingState = InksyncInkingState.shared
        let pencilOnly = isPad && (pencilOnlyDrawing || prefs.applePencilAutoDraw)
        uiView.isMarkupActive = isMarkupEnabled
        uiView.isInkLayerVisible = inkingState.isInkLayerVisible
        uiView.allowFingerDrawing = isMarkupEnabled && !pencilOnly
        uiView.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        uiView.isUserInteractionEnabled = isMarkupEnabled && inkingState.isInkLayerVisible
        uiView.drawingGestureRecognizer.cancelsTouchesInView = false
        uiView.isScrollEnabled = !pencilOnly
        uiView.bounces = false
        if pencilOnly {
            uiView.panGestureRecognizer.isEnabled = false
        }
        context.coordinator.canvasView = uiView
        
        // Keep Apple Pencil highlighter color dynamically synced with active user preference
        if let currentInk = uiView.tool as? PKInkingTool, currentInk.inkType == .marker {
            let activeColor = prefs.defaultHighlightColor.directHighlightUIColor
            if currentInk.color != activeColor {
                let updatedTool = PKInkingTool(.marker, color: activeColor, width: currentInk.width)
                uiView.tool = updatedTool
                context.coordinator.toolPicker?.selectedTool = updatedTool
            }
        }
        
        if isMarkupEnabled {
            DispatchQueue.main.async {
                if uiView.window != nil {
                    uiView.becomeFirstResponder()
                    context.coordinator.toolPicker?.setVisible(true, forFirstResponder: uiView)
                }
            }
        } else {
            uiView.resignFirstResponder()
            context.coordinator.toolPicker?.setVisible(false, forFirstResponder: uiView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleUIView(_ uiView: PassthroughPKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker?.setVisible(false, forFirstResponder: uiView)
        coordinator.toolPicker?.removeObserver(uiView)
        uiView.resignFirstResponder()
        coordinator.toolPicker = nil
        coordinator.canvasView = nil
    }
    
    class Coordinator: NSObject, UIPencilInteractionDelegate, PKCanvasViewDelegate {
        var toolPicker: PKToolPicker?
        weak var canvasView: PassthroughPKCanvasView?
        private var previousInkingTool: PKTool?
        private var isSnapping = false
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isSnapping else { return }
            if let snappedDrawing = SmartShapeRecognizer.snapLastStroke(in: canvasView.drawing) {
                isSnapping = true
                canvasView.drawing = snappedDrawing
                isSnapping = false
                HapticEngine.medium()
            }
        }
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard let canvas = canvasView else { return }
            HapticEngine.light()
            
            let fallbackTool: PKInkingTool = (EBookPreferences.shared.applePencilDefaultTool == "pen")
                ? PKInkingTool(.pen, color: .systemOrange, width: 3)
                : PKInkingTool(.marker, color: UIColor.systemYellow.withAlphaComponent(0.55), width: 22)
            
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser:
                if canvas.tool is PKEraserTool {
                    canvas.tool = previousInkingTool ?? fallbackTool
                } else {
                    previousInkingTool = canvas.tool
                    canvas.tool = PKEraserTool(.vector)
                }
            case .switchPrevious:
                if let prev = previousInkingTool {
                    let current = canvas.tool
                    canvas.tool = prev
                    previousInkingTool = current
                }
            case .showColorPalette, .showInkAttributes:
                toolPicker?.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            case .ignore:
                break
            default:
                // Covers .showContextualPalette and .runSystemShortcut (iOS 17.5+)
                // and any future cases Apple may add.  Showing the tool picker is
                // the safest fallback for all palette-adjacent actions.
                if #available(iOS 17.5, *) {
                    toolPicker?.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                } else {
                    // Pre-iOS 17.5: no additional cases exist; default to eraser toggle.
                    if canvas.tool is PKEraserTool {
                        canvas.tool = previousInkingTool ?? fallbackTool
                    } else {
                        previousInkingTool = canvas.tool
                        canvas.tool = PKEraserTool(.vector)
                    }
                }
            }
        }
        
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard let canvas = canvasView else { return }
            if squeeze.phase == .ended {
                HapticEngine.selection()
                if let picker = toolPicker {
                    picker.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                }
            }
        }
    }
}
