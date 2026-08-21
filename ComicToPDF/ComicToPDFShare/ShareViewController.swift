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
        guard let deepLinkURL = URL(string: "inksyncpro://shared-import") else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        // Write a pending-import flag to App Group UserDefaults BEFORE launching.
        // ContentView's willEnterForeground handler reads this flag and triggers
        // a library scan + Library tab navigation even if the URL callback is skipped
        // on iPadOS multi-window configurations.
        let groupIDs = [
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync",
            "group.com.antigravity.InksyncPro"
        ]
        for gid in groupIDs {
            if let ud = UserDefaults(suiteName: gid) {
                ud.set(Date().timeIntervalSince1970, forKey: "pendingShareImportTimestamp")
                ud.synchronize()
            }
        }

        // Strategy 1: extensionContext.open — works on iPhone and some iPad configs
        extensionContext?.open(deepLinkURL) { [weak self] success in
            if !success {
                // Strategy 2: iPad-safe fallback — complete with URL item so the system
                // passes it to the host app's scene(_:openURLContexts:) / AppDelegate.
                Task { @MainActor [weak self] in
                    let item = NSExtensionItem()
                    item.userInfo = ["openURL": deepLinkURL]
                    self?.extensionContext?.completeRequest(returningItems: [item])
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            }
        }
    }
}
