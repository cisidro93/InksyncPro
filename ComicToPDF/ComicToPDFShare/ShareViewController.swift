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

        // ── Step 2: Multi-Strategy Host App Launch (100% Crash-Immune via C ABI) ──
        var didOpen = false

        let openSelector = NSSelectorFromString("openURL:")
        let openOptsSelector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias OpenURLFunc = @convention(c) (NSObject, Selector, NSURL) -> Bool
        typealias OpenOptsFunc = @convention(c) (NSObject, Selector, NSURL, NSDictionary, ((Bool) -> Void)?) -> Void

        // Strategy A: UIResponder Chain Traversal (self -> window -> host application)
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: openOptsSelector) {
                if let imp = r.method(for: openOptsSelector) {
                    let fn = unsafeBitCast(imp, to: OpenOptsFunc.self)
                    fn(r, openOptsSelector, deepLinkURL as NSURL, [:] as NSDictionary) { [weak self] _ in
                        Task { @MainActor in
                            self?.completeHostAppHandover()
                        }
                    }
                    didOpen = true
                    break
                }
            } else if r.responds(to: openSelector) {
                if let imp = r.method(for: openSelector) {
                    let fn = unsafeBitCast(imp, to: OpenURLFunc.self)
                    _ = fn(r, openSelector, deepLinkURL as NSURL)
                    didOpen = true
                    break
                }
            }
            responder = r.next
        }

        if !didOpen {
            var winResponder: UIResponder? = self.view.window?.rootViewController ?? self.view.window
            while let r = winResponder {
                if r.responds(to: openOptsSelector) {
                    if let imp = r.method(for: openOptsSelector) {
                        let fn = unsafeBitCast(imp, to: OpenOptsFunc.self)
                        fn(r, openOptsSelector, deepLinkURL as NSURL, [:] as NSDictionary) { [weak self] _ in
                            Task { @MainActor in
                                self?.completeHostAppHandover()
                            }
                        }
                        didOpen = true
                        break
                    }
                } else if r.responds(to: openSelector) {
                    if let imp = r.method(for: openSelector) {
                        let fn = unsafeBitCast(imp, to: OpenURLFunc.self)
                        _ = fn(r, openSelector, deepLinkURL as NSURL)
                        didOpen = true
                        break
                    }
                }
                winResponder = r.next
            }
        }

        // Strategy B: Dynamic UIApplication Runtime Invocation (via C ABI)
        if !didOpen {
            if let appClass = NSClassFromString("UIApplication") as? NSObject.Type {
                let sharedAppSel = NSSelectorFromString("sharedApplication")
                if appClass.responds(to: sharedAppSel) {
                    typealias SharedAppFunc = @convention(c) (AnyClass, Selector) -> NSObject?
                    let sharedImp = appClass.method(for: sharedAppSel)
                    let sharedFn = unsafeBitCast(sharedImp, to: SharedAppFunc.self)
                    if let sharedApp = sharedFn(appClass, sharedAppSel) {
                        if sharedApp.responds(to: openOptsSelector) {
                            if let imp = sharedApp.method(for: openOptsSelector) {
                                let fn = unsafeBitCast(imp, to: OpenOptsFunc.self)
                                fn(sharedApp, openOptsSelector, deepLinkURL as NSURL, [:] as NSDictionary) { [weak self] _ in
                                    Task { @MainActor in
                                        self?.completeHostAppHandover()
                                    }
                                }
                                didOpen = true
                            }
                        } else if sharedApp.responds(to: openSelector) {
                            if let imp = sharedApp.method(for: openSelector) {
                                let fn = unsafeBitCast(imp, to: OpenURLFunc.self)
                                _ = fn(sharedApp, openSelector, deepLinkURL as NSURL)
                                didOpen = true
                            }
                        }
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

        // ── Step 3: Tactile Feedback & Clean Handover Teardown ──
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Dismiss the share extension cleanly after user-initiated tap
        let delayNanos: UInt64 = didOpen ? 600_000_000 : 400_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            self?.completeHostAppHandover()
        }
    }
}

