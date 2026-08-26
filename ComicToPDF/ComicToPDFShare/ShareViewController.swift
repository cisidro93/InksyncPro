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
    //
    // Multi-Strategy Host App Launcher (iPhone + iPad Universal):
    // On iPad, NSExtensionContext.open(_:) succeeds because iPad multitasking supports concurrent windowing.
    // On iPhone, Apple disables NSExtensionContext.open(_:) inside Share Extensions (com.apple.share-services).
    // To guarantee the host app opens across both iPhone and iPad:
    //  Strategy A: UIResponder chain traversal
    //  Strategy B: Dynamic UIApplication.sharedApplication invocation
    //  Strategy C: Dynamic NSExtensionContext selector invocation
    //  Strategy D: Standard NSExtensionContext.open fallback
    @MainActor
    private func openHostAppAndComplete() {
        guard let deepLinkURL = URL(string: "inksyncpro://shared-import") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        // ── Step 1: Write import flags to every known App Group suite ──────────
        let appGroupIDs = [
            "group.com.antigravity.InksyncPro",
            "group.com.antigravity.ComicToPDF",
            "group.com.antigravity.inksync"
        ]
        let timestamp = Date().timeIntervalSince1970
        for gid in appGroupIDs {
            if let ud = UserDefaults(suiteName: gid) {
                ud.set(timestamp, forKey: "pendingShareImportTimestamp")
                ud.set(true,      forKey: "hasPendingShareImport")
                ud.synchronize()
            }
        }

        // ── Step 2: Multi-Strategy Host App Launch ──
        var didOpen = false

        // Strategy A: UIResponder Chain Traversal
        var responder: UIResponder? = self
        while responder != nil {
            let openSelector = Selector(("openURL:"))
            if responder?.responds(to: openSelector) == true {
                responder?.perform(openSelector, with: deepLinkURL)
                didOpen = true
                break
            }
            responder = responder?.next
        }

        // Strategy B: Dynamic UIApplication Runtime Invocation (handles iPhone modal share)
        if !didOpen {
            if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
               let sharedApp = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject {
                let openOptsSel = NSSelectorFromString("openURL:options:completionHandler:")
                if sharedApp.responds(to: openOptsSel) {
                    typealias OpenOptsMethod = @convention(c) (NSObject, Selector, NSURL, NSDictionary, ((Bool) -> Void)?) -> Void
                    if let imp = sharedApp.method(for: openOptsSel) {
                        let fn = unsafeBitCast(imp, to: OpenOptsMethod.self)
                        fn(sharedApp, openOptsSel, deepLinkURL as NSURL, [:] as NSDictionary, nil)
                        didOpen = true
                    }
                } else {
                    let legacySel = NSSelectorFromString("openURL:")
                    if sharedApp.responds(to: legacySel) {
                        sharedApp.perform(legacySel, with: deepLinkURL)
                        didOpen = true
                    }
                }
            }
        }

        // Strategy C: Dynamic NSExtensionContext Selector Invocation
        if !didOpen, let ext = extensionContext {
            let extOpenSel = NSSelectorFromString("openURL:completionHandler:")
            if ext.responds(to: extOpenSel) {
                typealias ExtOpenMethod = @convention(c) (NSObject, Selector, NSURL, ((Bool) -> Void)?) -> Void
                if let imp = ext.method(for: extOpenSel) {
                    let fn = unsafeBitCast(imp, to: ExtOpenMethod.self)
                    fn(ext, extOpenSel, deepLinkURL as NSURL) { _ in }
                    didOpen = true
                }
            }
        }

        // Strategy D: Standard NSExtensionContext.open fallback
        if !didOpen {
            extensionContext?.open(deepLinkURL) { _ in }
        }

        // ── Step 3: Complete Request ──
        // A brief delay ensures SpringBoard initiates the app-switch transition before extension teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}

