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
        // The host app checks ALL three identifiers because provisioning profiles
        // sometimes only grant one of them, depending on the build configuration.
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

        // ── Step 2: Open the host app ──────────────────────────────────────────
        //
        // `extensionContext?.open(_:completionHandler:)` is the ONLY officially
        // documented API for activating the containing app from a Share Extension.
        //
        // We call `completeRequest` INSIDE the completion handler so that we never
        // signal extension completion before the system has confirmed the URL open
        // request has been dispatched to SpringBoard.
        //
        // IMPORTANT: if `open()` returns false (e.g., the scheme is not registered
        // or the device is in some edge-case state) we still complete gracefully;
        // the host app will pick up the files via the `willEnterForeground` flag on
        // next launch.

        extensionContext?.open(deepLinkURL, completionHandler: { [weak self] success in
            DispatchQueue.main.async {
                if !success {
                    // URL open was not dispatched — host app will pick up via flag.
                }
                self?.extensionContext?.completeRequest(
                    returningItems: nil,
                    completionHandler: nil
                )
            }
        })
    }
}
