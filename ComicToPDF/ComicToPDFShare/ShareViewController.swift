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

    // Per Apple's App Extension Programming Guide:
    // "An app extension does not have access to a UIApplication object for its
    //  containing app. The only supported way to open the host app from a Share
    //  Extension is NSExtensionContext.open(_:completionHandler:)."
    //
    // The previous implementation used NSClassFromString("UIApplication")
    // reflection to call openURL:options:completionHandler: which is a
    // documented no-op inside extension sandboxes on iOS 14+.
    @MainActor
    private func openHostAppAndComplete() {
        guard let deepLinkURL = URL(string: "inksyncpro://shared-import") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        // ── Step 1: Write import flags to every known App Group suite ──────────
        // Stamp timestamp LAST (after all files are confirmed written) so the
        // host app's willEnterForeground observer finds the correct state.
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

        // ── Step 2: Open host app via the ONLY Apple-documented extension API ──
        // NSExtensionContext.open(_:completionHandler:) is the sole supported
        // method to open the containing app from a Share Extension.
        // Ref: NSExtensionContext.h, UIKit Extension Programming Guide (WWDC 2014+)
        extensionContext?.open(deepLinkURL) { [weak self] success in
            // The completion handler fires on the main queue after the system
            // has attempted to foreground the host app.
            // Regardless of success, complete the extension so SpringBoard can
            // finish the transition.  A small delay ensures the host app has
            // received the willEnterForeground callback and started ingesting
            // files before our process is suspended.
            DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 0.4 : 0.1)) {
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
}

