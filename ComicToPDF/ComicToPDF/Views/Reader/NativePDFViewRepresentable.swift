import SwiftUI
import PDFKit
import UIKit

/// High-performance, lightweight UIKit wrapper around Apple's native `PDFView`.
/// Ensures 100% native vector rendering, fluid continuous scrolling, pinch-to-zoom,
/// text selection, and clean two-way page index synchronization.
struct NativePDFViewRepresentable: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var pdfViewRef: PDFView?
    var onPageChanged: ((Int) -> Void)? = nil
    var onTapCenter: (() -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .clear
        pdfView.isOpaque = false
        pdfView.insetsLayoutMarginsFromSafeArea = false
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 6.0
        pdfView.usePageViewController(false)

        // Native gesture recognizer for center tap chrome toggle
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        pdfView.addGestureRecognizer(tapGesture)

        // Double-tap gesture for native column/smart zoom
        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        doubleTapGesture.delegate = context.coordinator
        pdfView.addGestureRecognizer(doubleTapGesture)
        tapGesture.require(toFail: doubleTapGesture)

        // Register for standard PDFView page changes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pdfViewPageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        DispatchQueue.main.async {
            self.pdfViewRef = pdfView
            // Navigate to initial page
            if let initialPage = document.page(at: max(0, min(currentPageIndex, document.pageCount - 1))) {
                pdfView.go(to: initialPage)
            }
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document != document {
            uiView.document = document
        }

        // Navigate to target page if currentPageIndex changed externally
        if let current = uiView.currentPage, document.index(for: current) != currentPageIndex {
            if let targetPage = document.page(at: max(0, min(currentPageIndex, document.pageCount - 1))) {
                if context.coordinator.lastTargetIndex != currentPageIndex {
                    context.coordinator.lastTargetIndex = currentPageIndex
                    uiView.go(to: targetPage)
                }
            }
        } else {
            context.coordinator.lastTargetIndex = currentPageIndex
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: uiView)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: NativePDFViewRepresentable
        var lastTargetIndex: Int = -1

        init(_ parent: NativePDFViewRepresentable) {
            self.parent = parent
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            return true
        }

        @MainActor @objc func pdfViewPageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let index = doc.index(for: page)
            if index >= 0 && index < doc.pageCount && index != parent.currentPageIndex {
                parent.currentPageIndex = index
                parent.onPageChanged?(index)
            }
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView else { return }
            let point = gesture.location(in: pdfView)
            let width = pdfView.bounds.width
            
            // Middle 50% of the screen toggles chrome
            if point.x > width * 0.25 && point.x < width * 0.75 {
                parent.onTapCenter?()
            }
        }

        @MainActor @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView else { return }
            let fitScale = pdfView.scaleFactorForSizeToFit
            if pdfView.scaleFactor > fitScale * 1.3 {
                UIView.animate(withDuration: 0.3) {
                    pdfView.scaleFactor = fitScale
                }
            } else {
                UIView.animate(withDuration: 0.3) {
                    pdfView.scaleFactor = fitScale * 2.2
                }
            }
            HapticEngine.light()
        }
    }
}
