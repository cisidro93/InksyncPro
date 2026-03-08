import SwiftUI
import UIKit

// Wrapper to use iOS native UIPageViewController for 3D page curls
struct PageCurlReaderView<Page: View>: UIViewControllerRepresentable {
    var pages: [Page]
    @Binding var currentPageIndex: Int
    
    // Config
    var transitionStyle: UIPageViewController.TransitionStyle = .pageCurl
    var navigationOrientation: UIPageViewController.NavigationOrientation = .horizontal
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: navigationOrientation,
            options: [
                UIPageViewController.OptionsKey.interPageSpacing: 0
            ]
        )
        
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        
        // Add single-tap gesture to toggle UI if needed, or it can be handled externally
        
        if !pages.isEmpty {
            let initialVC = UIHostingController(rootView: pages[currentPageIndex])
            // Tag it so the coordinator knows its index
            initialVC.view.tag = currentPageIndex
            initialVC.view.backgroundColor = .clear // Let the dark theme show through
            
            pageViewController.setViewControllers([initialVC], direction: .forward, animated: false, completion: nil)
        }
        
        return pageViewController
    }
    
    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        // Only update if the binding changed externally and doesn't match current view
        if let currentVC = pageViewController.viewControllers?.first,
           currentVC.view.tag != currentPageIndex,
           pages.indices.contains(currentPageIndex) {
            
            let targetVC = UIHostingController(rootView: pages[currentPageIndex])
            targetVC.view.tag = currentPageIndex
            targetVC.view.backgroundColor = .clear
            
            let direction: UIPageViewController.NavigationDirection = currentPageIndex > currentVC.view.tag ? .forward : .reverse
            
            pageViewController.setViewControllers([targetVC], direction: direction, animated: true, completion: nil)
        } else if context.coordinator.parent.pages.count != pages.count {
            // Hot reload support if pages array changes
            context.coordinator.parent = self
            if pages.indices.contains(currentPageIndex) {
                let targetVC = UIHostingController(rootView: pages[currentPageIndex])
                targetVC.view.tag = currentPageIndex
                targetVC.view.backgroundColor = .clear
                pageViewController.setViewControllers([targetVC], direction: .forward, animated: false, completion: nil)
            }
        }
    }
    
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlReaderView
        
        init(_ parent: PageCurlReaderView) {
            self.parent = parent
        }
        
        // MARK: - DataSource
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            let index = viewController.view.tag
            if index <= 0 { return nil }
            
            let prevIndex = index - 1
            let vc = UIHostingController(rootView: parent.pages[prevIndex])
            vc.view.tag = prevIndex
            vc.view.backgroundColor = .clear
            return vc
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            let index = viewController.view.tag
            if index >= parent.pages.count - 1 { return nil }
            
            let nextIndex = index + 1
            let vc = UIHostingController(rootView: parent.pages[nextIndex])
            vc.view.tag = nextIndex
            vc.view.backgroundColor = .clear
            return vc
        }
        
        // MARK: - Delegate (Update Binding)
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let currentVC = pageViewController.viewControllers?.first {
                DispatchQueue.main.async {
                    self.parent.currentPageIndex = currentVC.view.tag
                }
            }
        }
    }
}
