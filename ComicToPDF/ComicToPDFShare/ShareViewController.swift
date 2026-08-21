import UIKit
import SwiftUI
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let contentView = ShareExtensionView(
            extensionContext: extensionContext,
            onDismiss: { [weak self] in
                self?.openHostAppAndComplete()
            }
        )
        
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
        // extensionContext.open is the ONLY valid mechanism to launch the host app
        // from an iOS Share Extension — the extension runs in a separate sandboxed
        // process and cannot access UIApplication.shared.
        guard let url = URL(string: "inksyncpro://shared-import"),
              let context = self.extensionContext else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        context.open(url) { [weak self] success in
            // Note: the completion handler success value is unreliable on iPadOS —
            // the system may return false even when the app successfully opens.
            // Always complete the extension request regardless.
            Task { @MainActor [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
}
