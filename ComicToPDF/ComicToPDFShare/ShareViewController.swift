import UIKit
import SwiftUI
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let contentView = ShareExtensionView(
            extensionContext: extensionContext,
            onCancel: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            },
            onOpenApp: { [weak self] in
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
        guard let deepLinkURL = URL(string: "inksyncpro://shared-import") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        // 1. Write pending-import flags to all App Group UserDefaults so the main app
        // automatically detects and scans imported documents upon entering foreground
        let groupIDs = [
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync",
            "group.com.antigravity.InksyncPro"
        ]
        for gid in groupIDs {
            if let ud = UserDefaults(suiteName: gid) {
                ud.set(Date().timeIntervalSince1970, forKey: "pendingShareImportTimestamp")
                ud.set(true, forKey: "hasPendingShareImport")
                ud.synchronize()
            }
        }

        // 2. Dispatch URL open via UIResponder chain (standard for iOS Share Extensions)
        var responder: UIResponder? = self
        while let current = responder {
            let selector = NSSelectorFromString("openURL:")
            if current.responds(to: selector) {
                current.perform(selector, with: deepLinkURL)
                break
            }
            responder = current.next
        }

        // 3. Fallback to extensionContext.open
        if let context = extensionContext {
            let openSelector = NSSelectorFromString("openURL:completionHandler:")
            if context.responds(to: openSelector) {
                context.open(deepLinkURL) { _ in }
            }
        }

        // 4. Delayed dismissal (350ms): prevents SpringBoard from aborting the app activation
        // before the extension process is detached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            let item = NSExtensionItem()
            item.userInfo = ["openURL": deepLinkURL]
            self?.extensionContext?.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
