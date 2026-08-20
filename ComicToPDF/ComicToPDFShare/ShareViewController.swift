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
    
    private func openHostAppAndComplete() {
        if let url = URL(string: "inksyncpro://shared-import") {
            // Attempt opening via UIResponder selector traversal
            var responder: UIResponder? = self
            var didOpen = false
            while responder != nil {
                if let application = responder as? UIApplication {
                    application.open(url, options: [:], completionHandler: nil)
                    didOpen = true
                    break
                }
                let selector = NSSelectorFromString("openURL:")
                if responder?.responds(to: selector) == true {
                    responder?.perform(selector, with: url)
                    didOpen = true
                    break
                }
                responder = responder?.next
            }
            
            if !didOpen {
                self.extensionContext?.open(url, completionHandler: nil)
            }
        }
        
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
