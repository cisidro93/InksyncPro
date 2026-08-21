import UIKit
import SwiftUI
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Create SwiftUI view
        let contentView = ShareExtensionView(
            extensionContext: extensionContext,
            onDismiss: { [weak self] in
                self?.openHostAppAndComplete()
            }
        )
        
        // Host SwiftUI in UIKit
        let hostingController = UIHostingController(rootView: contentView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        hostingController.didMove(toParent: self)
    }
    
    @MainActor
    private func openHostAppAndComplete() {
        guard let url = URL(string: "inksyncpro://shared-import") else {
            self.completeShareExtension()
            return
        }
        
        var didOpen = false
        
        // Strategy 1: Responder chain traversal for UIApplication
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                didOpen = true
                break
            }
            responder = responder?.next
        }
        
        // Strategy 2: Selector reflection on responder chain
        if !didOpen {
            let selector = NSSelectorFromString("openURL:")
            var current: UIResponder? = self
            while let r = current {
                if r.responds(to: selector) {
                    r.perform(selector, with: url)
                    didOpen = true
                    break
                }
                current = r.next
            }
        }
        
        // Strategy 3: NSExtensionContext fallback
        if !didOpen, let context = self.extensionContext {
            context.open(url) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.completeShareExtension()
                }
            }
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.completeShareExtension()
        }
    }

    @MainActor
    private func completeShareExtension() {
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
