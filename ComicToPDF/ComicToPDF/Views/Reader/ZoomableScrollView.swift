import SwiftUI
import UIKit

/// A robust UIKit wrapper replacing SwiftUI's native pinch-to-zoom.
/// Provides buttery-smooth 60fps zooming, momentum panning, and Double-Tap to Zoom.
/// Correctly resets zoom scale on rotation to prevent broken layout after device rotation.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    private var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast // Snap feel matching Apple Photos

        let hostingController = UIHostingController(rootView: content)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear

        scrollView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            // Lock the content width/height to the scroll view frame so the image starts full-screen.
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hostingController.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        // Hold a weak reference inside the coordinator to break the retain cycle.
        context.coordinator.hostingController = hostingController

        // Double-Tap to Zoom
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Reset zoom on rotation so layout doesn't break after an orientation change.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleOrientationChange(_:)),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController?.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        // Weak reference to break the retain cycle between Coordinator ↔ ZoomableScrollView.
        weak var hostingController: UIHostingController<Content>?
        // Hold a weak ref to the scroll view for rotation reset.
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            self.scrollView = scrollView
            return hostingController?.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = hostingController?.view else { return }
            // Re-center the content whenever zoom changes so there's no dead
            // black space around the comic page when zoomed below fill size.
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            view.center = CGPoint(
                x: scrollView.contentSize.width * 0.5 + offsetX,
                y: scrollView.contentSize.height * 0.5 + offsetY
            )
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                // Already zoomed in — snap back to fit.
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom 2.5x centered on the exact tap coordinate.
                let tapPoint = recognizer.location(in: hostingController?.view)
                let zoomScale: CGFloat = 2.5
                let size = CGSize(
                    width: scrollView.bounds.size.width / zoomScale,
                    height: scrollView.bounds.size.height / zoomScale
                )
                let origin = CGPoint(
                    x: tapPoint.x - (size.width / 2.0),
                    y: tapPoint.y - (size.height / 2.0)
                )
                scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
            }
        }

        @objc func handleOrientationChange(_ notification: Notification) {
            // Snap back to minimum zoom on rotation to prevent broken layout.
            // The debounced ReaderView state update will then re-render the page at
            // the correct size automatically.
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                UIView.animate(withDuration: 0.2) {
                    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                }
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
