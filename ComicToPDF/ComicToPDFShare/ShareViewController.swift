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
        
        // Strategy 1: Dynamic UIApplication invocation via Obj-C runtime (Universal iOS Extension pattern)
        if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
           let sharedApp = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject {
            let openSelector = NSSelectorFromString("openURL:options:completionHandler:")
            if sharedApp.responds(to: openSelector) {
                typealias OpenURLMethod = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let methodIMP = sharedApp.method(for: openSelector)
                let openFunc = unsafeBitCast(methodIMP, to: OpenURLMethod.self)
                openFunc(sharedApp, openSelector, url as NSURL, [:] as NSDictionary, { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.completeShareExtension()
                    }
                })
                return
            } else {
                let simpleOpen = NSSelectorFromString("openURL:")
                if sharedApp.responds(to: simpleOpen) {
                    _ = sharedApp.perform(simpleOpen, with: url)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.completeShareExtension()
                    }
                    return
                }
            }
        }
        
        // Strategy 2: Responder chain traversal for openURL:
        let selector = NSSelectorFromString("openURL:")
        var current: UIResponder? = self
        while let r = current {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.completeShareExtension()
                }
                return
            }
            current = r.next
        }
        
        // Strategy 3: NSExtensionContext fallback
        if let context = self.extensionContext {
            context.open(url) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.completeShareExtension()
                }
            }
            return
        }
        
        self.completeShareExtension()
    }

    @MainActor
    private func completeShareExtension() {
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
