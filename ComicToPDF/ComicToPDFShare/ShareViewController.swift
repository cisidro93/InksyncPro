import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ShareViewController
//
// The correct iOS Share Extension open-host-app pattern (iOS 17):
//
//  1. Present the SwiftUI UI.
//  2. When the user taps "Import", the SwiftUI view copies files to the
//     App Group container and calls `onOpenApp`.
//  3. `openHostAppAndComplete()` uses `extensionContext?.open(_:completionHandler:)`
//     — the ONLY documented method for opening the host app from a Share Extension
//     (UIResponder chain traversal was removed in iOS 13+).
//  4. The completion handler of `open()` is called on the extension's main thread.
//     Inside it we call `completeRequest` — this guarantees that SpringBoard has
//     already foregrounded the host app before we signal extension completion.
//  5. We write `pendingShareImportTimestamp` to ALL known App Group suites so the
//     host app's `willEnterForeground` observer detects the import even if
//     `onOpenURL` is never called (which can happen in iPad split-view).

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

    // MARK: - Host App Activation

    @MainActor
    private func openHostAppAndComplete() {
        guard let deepLinkURL = URL(string: "inksyncpro://shared-import") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        // ── Step 1: Write import flags to every known App Group suite ──────────
        let appGroupIDs = [
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync",
            "group.com.antigravity.InksyncPro"
        ]
        let timestamp = Date().timeIntervalSince1970
        for gid in appGroupIDs {
            if let ud = UserDefaults(suiteName: gid) {
                ud.set(timestamp, forKey: "pendingShareImportTimestamp")
                ud.set(true,      forKey: "hasPendingShareImport")
                ud.synchronize()
            }
        }

        // ── Step 2: Open host app via UIApplication shared instance ───────────
        if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
           let sharedApp = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject {
            
            let openWithCompletionSel = NSSelectorFromString("openURL:options:completionHandler:")
            if sharedApp.responds(to: openWithCompletionSel) {
                typealias OpenWithCompletion = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                if let method = sharedApp.method(for: openWithCompletionSel) {
                    let openImp = unsafeBitCast(method, to: OpenWithCompletion.self)
                    openImp(sharedApp, openWithCompletionSel, deepLinkURL as NSURL, [:] as NSDictionary) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                        }
                    }
                    return
                }
            }

            let legacyOpenSel = NSSelectorFromString("openURL:")
            if sharedApp.responds(to: legacyOpenSel) {
                typealias LegacyOpen = @convention(c) (AnyObject, Selector, NSURL) -> Bool
                if let method = sharedApp.method(for: legacyOpenSel) {
                    let openImp = unsafeBitCast(method, to: LegacyOpen.self)
                    _ = openImp(sharedApp, legacyOpenSel, deepLinkURL as NSURL)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                    }
                    return
                }
            }
        }

        // Fallback: extensionContext?.open
        extensionContext?.open(deepLinkURL, completionHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        })
    }
}
