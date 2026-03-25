import SwiftUI
import PDFKit
import PencilKit

struct DocumentReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    
    @State private var chromeVisible = false
    @State private var currentPageIndex: Int = 0
    @State private var isPencilMode = false
    @State private var pdfDocument: PDFDocument?
    
    // KOReader Parity
    @State private var isReflowMode = false
    @State private var reflowText: String = "Extracting text..."
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all)
            
            if isReflowMode {
                ScrollView {
                    Text(reflowText)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(8)
                        .padding(24)
                        .padding(.top, 40)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor(Color(UIColor.label))
                }
                .background(Color(UIColor.systemBackground))
                .onTapGesture {
                    chromeVisible.toggle()
                }
            } else if let doc = pdfDocument {
                PDFKitRepresentedView(document: doc,
                                      pdf: pdf,
                                      currentPageIndex: $currentPageIndex,
                                      chromeVisible: $chromeVisible,
                                      isPencilMode: $isPencilMode)
            } else {
                ProgressView("Loading Document...")
            }
            
            ReaderChrome(
                pdf: pdf,
                title: pdf.name,
                pageText: "\(currentPageIndex + 1) / \(pdf.pageCount)",
                isVisible: $chromeVisible,
                onBack: {
                    ReaderProgressTracker.shared.update(ReadingProgress(
                        pdfID: pdf.id, lastOpenedAt: Date(), currentPageIndex: currentPageIndex,
                        currentChapterIndex: nil, currentChapterOffset: nil,
                        totalPagesRead: 1, completionFraction: Double(currentPageIndex + 1) / Double(max(1, pdf.pageCount)),
                        readingSessionDates: [Date()], estimatedMinutesRemaining: nil
                    ))
                    onDismiss()
                },
                onEInkSend: {},
                onBookmark: {
                    let bookmark = Annotation(pdfID: pdf.id, pageIndex: currentPageIndex, kind: .bookmark, createdAt: Date(), modifiedAt: Date())
                    AnnotationStore.shared.add(bookmark)
                },
                onAnnotationsToggle: {
                    isPencilMode.toggle()
                },
                onSettingsToggle: {},
                currentProgress: Binding(
                    get: { Double(currentPageIndex) / Double(max(1, pdf.pageCount - 1)) },
                    set: {
                        currentPageIndex = Int($0 * Double(max(1, pdf.pageCount - 1)))
                    }
                ),
                totalPages: pdf.pageCount,
                isPDF: true,
                isReflowActive: isReflowMode,
                onCropToggle: { applySmartCrop() },
                onReflowToggle: {
                    isReflowMode.toggle()
                    if isReflowMode { updateReflowText() }
                }
            )
            
            if isPencilMode && !isReflowMode {
                // Overlay PencilKit ToolPicker Indicator
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Pencil Mode Active")
                            .font(.caption)
                            .padding(8)
                            .background(Color.blue.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding()
                    }
                    .padding(.bottom, 60)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let doc = PDFDocument(url: pdf.url)
                DispatchQueue.main.async {
                    self.pdfDocument = doc
                    if let saved = ReaderProgressTracker.shared.progress(for: pdf.id) {
                        self.currentPageIndex = saved.currentPageIndex
                    }
                    if isReflowMode { updateReflowText() }
                }
            }
        }
        .onChange(of: currentPageIndex) { old, new in
            if isReflowMode { updateReflowText() }
        }
    }
    
    // MARK: KOReader Parity Dynamics
    
    private func updateReflowText() {
        guard let doc = pdfDocument, let page = doc.page(at: currentPageIndex) else { return }
        let extracted = page.string ?? ""
        self.reflowText = extracted.isEmpty ? "No extractable text on this page." : extracted
    }
    
    private func applySmartCrop() {
        guard let doc = pdfDocument else { return }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                // Approximate KOReader margin clip by aggressively cutting 12% padding
                var crop = page.bounds(for: .cropBox)
                crop = crop.insetBy(dx: crop.width * 0.12, dy: crop.height * 0.12)
                page.setBounds(crop, for: .cropBox)
            }
        }
        // Force PDFView to redraw the structural bounds
        self.pdfDocument = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.pdfDocument = doc
        }
    }
}

// SwiftUI PDFView wrapper
struct PDFKitRepresentedView: UIViewRepresentable {
    let document: PDFDocument
    let pdf: ConvertedPDF
    @Binding var currentPageIndex: Int
    @Binding var chromeVisible: Bool
    @Binding var isPencilMode: Bool
    
    func makeUIView(context: Context) -> UIView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.displayMode = pdf.documentSubtype == .magazine ? .singlePageContinuous : .singlePageContinuous
        pdfView.delegate = context.coordinator
        
        let canvasView = PKCanvasView()
        canvasView.isOpaque = false
        canvasView.backgroundColor = .clear
        canvasView.drawingPolicy = .pencilOnly
        canvasView.delegate = context.coordinator
        
        // Disable canvas initially
        canvasView.isUserInteractionEnabled = false
        
        context.coordinator.pdfView = pdfView
        context.coordinator.canvasView = canvasView
        
        let container = UIView()
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(pdfView)
        
        canvasView.frame = container.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(canvasView)
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleTap(_:)))
        pdfView.addGestureRecognizer(tap)
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.canvasView?.isUserInteractionEnabled = isPencilMode
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PDFViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver {
        var parent: PDFKitRepresentedView
        weak var pdfView: PDFView?
        weak var canvasView: PKCanvasView?
        var toolPicker = PKToolPicker()
        
        init(_ parent: PDFKitRepresentedView) {
            self.parent = parent
            super.init()
            toolPicker.addObserver(self)
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !parent.isPencilMode else { return }
            parent.chromeVisible.toggle()
        }
        
        @objc func pageChanged(_ notification: Notification) {
            if let view = notification.object as? PDFView, let page = view.currentPage, let document = view.document {
                DispatchQueue.main.async {
                    self.parent.currentPageIndex = document.index(for: page)
                }
            }
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Save ink annotation to AnnotationStore mapped to the current page
            guard let pdfView = pdfView, let page = pdfView.currentPage else { return }
            let index = parent.document.index(for: page)
            
            // Map PKDrawing bounds to PDF Page normalized coords for AnnotationStore
            let viewBounds = canvasView.bounds
            let drawingBounds = canvasView.drawing.bounds
            let normalizedBounds = CodableCGRect(
                x: Double(drawingBounds.minX / viewBounds.width),
                y: Double(drawingBounds.minY / viewBounds.height),
                width: Double(drawingBounds.width / viewBounds.width),
                height: Double(drawingBounds.height / viewBounds.height)
            )
            
            let annotation = Annotation(
                pdfID: parent.pdf.id,
                pageIndex: index,
                kind: .ink,
                createdAt: Date(),
                modifiedAt: Date(),
                bounds: normalizedBounds
            )
            AnnotationStore.shared.add(annotation)
        }
    }
}
