import UIKit
import PDFKit
import PencilKit
import Combine
import SwiftData

extension PDFPage: @retroactive @unchecked Sendable {}

// MARK: - PDFPageCanvasProvider

/// High-performance, zero-drift canvas provider for PDFKit utilizing Apple's native
/// `PDFPageOverlayViewProvider` (iOS 16+). Directly anchors scoped `PassthroughPKCanvasView`
/// overlays into each `PDFPageView` scroll tile, guaranteeing zero coordinate drift on zoom,
/// full 120Hz ProMotion touch responsiveness, and seamless finger gesture pass-through.
@MainActor
public final class PDFPageCanvasProvider: NSObject, PKCanvasViewDelegate {

    public var pdfID: UUID?
    public var isMarkupActive: Bool = false {
        didSet {
            updateCanvasInteractivity()
        }
    }

    private var pageCanvases: [ObjectIdentifier: PassthroughPKCanvasView] = [:]
    private var loadedPages: Set<ObjectIdentifier> = []
    private var debounceSaveTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    public init(pdfID: UUID? = nil, isMarkupActive: Bool = false) {
        self.pdfID = pdfID
        self.isMarkupActive = isMarkupActive
        super.init()

        // Synchronize all visible page canvases when the user changes inking tools or colors
        InksyncInkingState.shared.$activePreset
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAllCanvasTools()
            }
            .store(in: &cancellables)

        InksyncInkingState.shared.$activeToolMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAllCanvasTools()
                self?.updateCanvasInteractivity()
            }
            .store(in: &cancellables)

        InksyncInkingState.shared.$eraserType
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAllCanvasTools()
            }
            .store(in: &cancellables)

        InksyncInkingState.shared.$isColoringModeActive
            .receive(on: RunLoop.main)
            .sink { [weak self] isColoring in
                self?.updateColoringMode(isColoring)
            }
            .store(in: &cancellables)
    }

    // MARK: - Overlay View Provider Methods (MainActor)

    public func overlayView(for page: PDFPage) -> UIView? {
        let key = ObjectIdentifier(page)
        if let existing = pageCanvases[key] {
            return existing
        }

        guard let doc = page.document else { return nil }
        let pageIdx = doc.index(for: page)
        guard pageIdx >= 0 else { return nil }

        let pageSize = page.bounds(for: .cropBox).size
        let frame = CGRect(origin: .zero, size: pageSize)
        let canvas = PassthroughPKCanvasView(frame: frame)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.overrideUserInterfaceStyle = .light
        canvas.pageIndex = pageIdx
        canvas.associatedPage = page
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.bounces = false
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.delegate = self
        canvas.isColoringMode = InksyncInkingState.shared.isColoringModeActive

        configureCanvasPolicy(canvas)
        canvas.tool = InksyncInkingState.shared.makePKTool()

        pageCanvases[key] = canvas
        return canvas
    }

    public func willDisplay(overlayView: UIView, for page: PDFPage) {
        let key = ObjectIdentifier(page)
        guard let canvas = overlayView as? PassthroughPKCanvasView else { return }

        configureCanvasPolicy(canvas)
        canvas.tool = InksyncInkingState.shared.makePKTool()
        canvas.isColoringMode = InksyncInkingState.shared.isColoringModeActive
        if InksyncInkingState.shared.isColoringModeActive {
            Task { @MainActor in
                if let mask = await ColoringLineartEngine.shared.lineartMask(for: page) {
                    canvas.setLineartMask(mask)
                }
            }
        } else {
            canvas.updateLineartVisibility()
        }

        guard !loadedPages.contains(key) else { return }

        loadDrawing(into: canvas, for: page)
        loadedPages.insert(key)
    }

    public func willEndDisplaying(overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PassthroughPKCanvasView else { return }
        let key = ObjectIdentifier(page)

        // Cancel debounce and force an immediate disk write
        if let pending = debounceSaveTasks[key] {
            pending.cancel()
            debounceSaveTasks.removeValue(forKey: key)
            saveDrawing(from: canvas, for: page)
        }
    }

    // MARK: - PKCanvasViewDelegate

    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PassthroughPKCanvasView,
              let page = canvas.associatedPage else { return }

        let key = ObjectIdentifier(page)
        debounceSaveTasks[key]?.cancel()

        debounceSaveTasks[key] = Task { [weak self, weak canvas, weak page] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled, let self = self, let canvas = canvas, let page = page else { return }
            self.saveDrawing(from: canvas, for: page)
        }
    }

    // MARK: - Canvas Interactivity & Tool Updates

    public func updateCanvasInteractivity() {
        for canvas in pageCanvases.values {
            configureCanvasPolicy(canvas)
        }
    }

    public func updateColoringMode(_ isColoring: Bool) {
        for canvas in pageCanvases.values {
            canvas.isColoringMode = isColoring
            if isColoring, let page = canvas.associatedPage {
                Task { @MainActor in
                    if let mask = await ColoringLineartEngine.shared.lineartMask(for: page) {
                        canvas.setLineartMask(mask)
                    }
                }
            } else {
                canvas.updateLineartVisibility()
            }
        }
        updateCanvasInteractivity()
    }

    public func updateAllCanvasTools() {
        let currentTool = InksyncInkingState.shared.makePKTool()
        for canvas in pageCanvases.values {
            canvas.tool = currentTool
        }
    }

    private func configureCanvasPolicy(_ canvas: PassthroughPKCanvasView) {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefs = EBookPreferences.shared
        let pencilOnlyDrawingSetting = AppSettingsManager.shared.conversionSettings.pencilOnlyDrawing
        let currentMode = InksyncInkingState.shared.activeToolMode
        let isWriting = currentMode == .write
        let isEraser = currentMode == .eraser
        let isColoring = InksyncInkingState.shared.isColoringModeActive
        let autoPenActive = isPad && prefs.applePencilAutoDraw && prefs.applePencilDefaultTool == "pen"
        let shouldBeActive = isWriting || isEraser || isColoring || isMarkupActive || autoPenActive

        canvas.overrideUserInterfaceStyle = .light
        canvas.isMarkupActive = shouldBeActive
        let allowFinger = !pencilOnlyDrawingSetting || isEraser
        canvas.allowFingerDrawing = allowFinger
        canvas.drawingPolicy = (pencilOnlyDrawingSetting && !allowFinger) ? .pencilOnly : .anyInput
        canvas.isUserInteractionEnabled = shouldBeActive
        canvas.drawingGestureRecognizer.cancelsTouchesInView = false
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.panGestureRecognizer.isEnabled = !pencilOnlyDrawingSetting
    }

    // MARK: - Persistence & OCR Synchronization

    private func loadDrawing(into canvas: PassthroughPKCanvasView, for page: PDFPage) {
        guard let pdfID = pdfID else { return }
        let targetID = pdfID
        let pageIdx = canvas.pageIndex
        let ctx = InksyncProApp.sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate {
            $0.pdfID == targetID && $0.pageIndex == pageIdx && $0.kindRaw == "ink"
        })

        if let existing = try? ctx.fetch(descriptor).first,
           let data = existing.drawingData,
           let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        } else {
            // Check in-memory store fallback
            if let storeAnn = AnnotationStore.shared.annotations(for: targetID).first(where: {
                $0.pageIndex == pageIdx && $0.kind == .ink
            }), let data = storeAnn.drawingData, let drawing = try? PKDrawing(data: data) {
                canvas.drawing = drawing
            } else {
                canvas.drawing = PKDrawing()
            }
        }
    }

    private func saveDrawing(from canvas: PassthroughPKCanvasView, for page: PDFPage) {
        guard let pdfID = pdfID else { return }
        let drawing = canvas.drawing
        let pageIdx = canvas.pageIndex
        let drawingData = drawing.dataRepresentation()
        let ctx = InksyncProApp.sharedModelContainer.mainContext

        let descriptor = FetchDescriptor<SDAnnotation>(predicate: #Predicate {
            $0.pdfID == pdfID && $0.pageIndex == pageIdx && $0.kindRaw == "ink"
        })

        let existing = try? ctx.fetch(descriptor).first

        // If drawing is empty and nothing was saved, do not pollute database
        if drawing.bounds.isEmpty && existing == nil {
            return
        }

        if let annotation = existing {
            annotation.drawingData = drawingData
            annotation.modifiedAt = Date()
            try? ctx.save()

            var storeDto = annotation.toDTO()
            storeDto.drawingData = drawingData
            AnnotationStore.shared.update(storeDto)

            runOCR(for: annotation, drawing: drawing)
        } else {
            var dto = Annotation(
                id: UUID(),
                pdfID: pdfID,
                pageIndex: pageIdx,
                chapterTitle: nil,
                kind: .ink,
                createdAt: Date(),
                modifiedAt: Date()
            )
            dto.drawingData = drawingData
            let newInk = SDAnnotation(from: dto)
            ctx.insert(newInk)
            try? ctx.save()
            AnnotationStore.shared.add(dto)

            runOCR(for: newInk, drawing: drawing)
        }
    }

    private func runOCR(for annotation: SDAnnotation, drawing: PKDrawing) {
        guard !drawing.bounds.isEmpty else {
            SpotlightIndexer.shared.indexAnnotation(annotation)
            return
        }

        Task { @MainActor in
            if let ocrText = await HandwritingOCRManager.shared.recognizeHandwriting(in: drawing) {
                if annotation.drawingOCRText != ocrText {
                    annotation.drawingOCRText = ocrText
                    annotation.modifiedAt = Date()
                    try? InksyncProApp.sharedModelContainer.mainContext.save()
                    Logger.shared.log("Page ink OCR updated for page \(annotation.pageIndex): \(ocrText.prefix(40))...", category: "OCR", type: .success)
                    SpotlightIndexer.shared.indexAnnotation(annotation)
                }
            } else {
                SpotlightIndexer.shared.indexAnnotation(annotation)
            }
        }
    }

    // MARK: - Actions

    public func undo(for pageIndex: Int) -> Bool {
        for canvas in pageCanvases.values where canvas.pageIndex == pageIndex {
            if canvas.undoManager?.canUndo == true {
                canvas.undoManager?.undo()
                return true
            }
        }
        return false
    }

    public func redo(for pageIndex: Int) -> Bool {
        for canvas in pageCanvases.values where canvas.pageIndex == pageIndex {
            if canvas.undoManager?.canRedo == true {
                canvas.undoManager?.redo()
                return true
            }
        }
        return false
    }

    public func undoVisible(preferredPageIndex: Int? = nil) -> Bool {
        if let preferred = preferredPageIndex, undo(for: preferred) {
            return true
        }
        for canvas in pageCanvases.values {
            if canvas.undoManager?.canUndo == true {
                canvas.undoManager?.undo()
                return true
            }
        }
        return false
    }

    public func redoVisible(preferredPageIndex: Int? = nil) -> Bool {
        if let preferred = preferredPageIndex, redo(for: preferred) {
            return true
        }
        for canvas in pageCanvases.values {
            if canvas.undoManager?.canRedo == true {
                canvas.undoManager?.redo()
                return true
            }
        }
        return false
    }

    public func canUndo(for pageIndex: Int) -> Bool {
        return pageCanvases.values.contains { $0.pageIndex == pageIndex && $0.undoManager?.canUndo == true }
    }

    public func canRedo(for pageIndex: Int) -> Bool {
        return pageCanvases.values.contains { $0.pageIndex == pageIndex && $0.undoManager?.canRedo == true }
    }

    public func clearDrawing(for pageIndex: Int) {
        for canvas in pageCanvases.values where canvas.pageIndex == pageIndex {
            canvas.drawing = PKDrawing()
            if let page = canvas.associatedPage {
                let key = ObjectIdentifier(page)
                debounceSaveTasks[key]?.cancel()
                debounceSaveTasks.removeValue(forKey: key)
                saveDrawing(from: canvas, for: page)
            }
        }
    }
}

// MARK: - PDFPageOverlayViewProvider Conformance

extension PDFPageCanvasProvider: PDFPageOverlayViewProvider {

    @objc(pdfView:overlayViewForPage:)
    public nonisolated func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        MainActor.assumeIsolated {
            self.overlayView(for: page)
        }
    }

    @objc(pdfView:willDisplayOverlayView:forPage:)
    public nonisolated func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        MainActor.assumeIsolated {
            self.willDisplay(overlayView: overlayView, for: page)
        }
    }

    @objc(pdfView:willEndDisplayingOverlayView:forPage:)
    public nonisolated func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        MainActor.assumeIsolated {
            self.willEndDisplaying(overlayView: overlayView, for: page)
        }
    }
}
