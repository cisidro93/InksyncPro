import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ShareViewController
//
// Crash-Immune iOS Share Extension open-host-app pattern:
//
//  1. Present the SwiftUI UI.
//  2. When the user taps "Import to InkSync Pro Library", the view stages files
//     to the primary App Group container and triggers `onOpenApp`.
//  3. `openHostAppAndComplete()` uses a multi-strategy launcher:
//     - Strategy A: UIResponder chain traversal for `openURL:`.
//     - Strategy B: Dynamic `UIApplication.sharedApplication` invocation.
//     - Strategy C: `extensionContext` dynamic method invocation strictly guarded by `responds(to:)`.
//     NOTE: Calling `extensionContext.open()` directly causes `NSInvalidArgumentException`
//     because `_UIActivityExtensionContext` does not implement `openURL:completionHandler:`
//     on Share Extensions (it is restricted to Today/iMessage extensions).
//  4. `completeHostAppHandover()` completes the extension request smoothly after handover.
//  5. Write `pendingShareImportTimestamp` and `hasPendingShareImport` to all App Group suites.

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let contentView = ShareExtensionView(
            extensionContext: extensionContext,
            onCancel: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            },
            onOpenApp: { [weak self] files in
                self?.openHostAppAndComplete(files: files)
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
    private var didFinishRequest = false

    @MainActor
    private func completeHostAppHandover() {
        guard !didFinishRequest else { return }
        didFinishRequest = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @MainActor
    private func openHostAppAndComplete(files: [SharedFile]) {
        var urlComponents = URLComponents(string: "inksyncpro://shared-import")!
        if let first = files.first {
            urlComponents.queryItems = [URLQueryItem(name: "file", value: first.name)]
        }
        let deepLinkURL = urlComponents.url ?? URL(string: "inksyncpro://shared-import")!

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

        // ── Step 2: Multi-Strategy Host App Launch (Crash-Immune) ──
        var didOpen = false

        // Strategy A: UIResponder Chain Traversal (self -> window -> host application)
        var responder: UIResponder? = self
        let openSelector = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: openSelector) {
                _ = r.perform(openSelector, with: deepLinkURL)
                didOpen = true
                break
            }
            responder = r.next
        }
        if !didOpen {
            var winResponder: UIResponder? = self.view.window?.rootViewController ?? self.view.window
            while let r = winResponder {
                if r.responds(to: openSelector) {
                    _ = r.perform(openSelector, with: deepLinkURL)
                    didOpen = true
                    break
                }
                winResponder = r.next
            }
        }

        // Strategy B: Dynamic UIApplication Runtime Invocation
        if !didOpen {
            if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
               let sharedApp = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject {
                let openOptsSel = NSSelectorFromString("openURL:options:completionHandler:")
                if sharedApp.responds(to: openOptsSel) {
                    typealias OpenOptsMethod = @convention(c) (NSObject, Selector, NSURL, NSDictionary, ((Bool) -> Void)?) -> Void
                    if let imp = sharedApp.method(for: openOptsSel) {
                        let fn = unsafeBitCast(imp, to: OpenOptsMethod.self)
                        fn(sharedApp, openOptsSel, deepLinkURL as NSURL, [:] as NSDictionary) { [weak self] _ in
                            Task { @MainActor in
                                self?.completeHostAppHandover()
                            }
                        }
                        didOpen = true
                    }
                } else {
                    let legacySel = NSSelectorFromString("openURL:")
                    if sharedApp.responds(to: legacySel) {
                        _ = sharedApp.perform(legacySel, with: deepLinkURL)
                        didOpen = true
                    }
                }
            }
        }

        // Strategy C: Dynamic NSExtensionContext Selector Check
        // Strictly guarded with responds(to:) so _UIActivityExtensionContext NEVER throws unrecognized selector exception
        if !didOpen, let ext = extensionContext {
            let extOpenSel = NSSelectorFromString("openURL:completionHandler:")
            if ext.responds(to: extOpenSel) {
                typealias ExtOpenMethod = @convention(c) (NSObject, Selector, NSURL, ((Bool) -> Void)?) -> Void
                if let imp = ext.method(for: extOpenSel) {
                    let fn = unsafeBitCast(imp, to: ExtOpenMethod.self)
                    fn(ext, extOpenSel, deepLinkURL as NSURL) { [weak self] _ in
                        Task { @MainActor in
                            self?.completeHostAppHandover()
                        }
                    }
                    didOpen = true
                }
            }
        }

        // ── Step 3: Safety Fallback Teardown ──
        // If SpringBoard accepted the open, complete smoothly after transition.
        // If system restricts auto-launching (e.g. iOS 18), give the user 4s to tap "Done" or "Open InkSync Pro".
        let delayNanos: UInt64 = didOpen ? 800_000_000 : 4_000_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            self?.completeHostAppHandover()
        }
    }
}

