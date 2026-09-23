import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ShareViewController
//
// Modern iOS Share Extension host-app launch architecture:
//
//  1. Present the SwiftUI UI (ShareExtensionView).
//  2. When the user taps "Import to InkSync Pro Library", files are staged
//     to the App Group containers and bridged unconditionally to UIPasteboard.general.
//  3. The "Open InkSync Pro" button is rendered as a native SwiftUI Link(destination: deepLinkURL).
//     Direct user interaction with SwiftUI Link activates SpringBoard's system URL dispatcher,
//     reliably launching the host app on iOS 17 and iOS 18 without hitting sandbox selector restrictions.
//  4. Simultaneously, onOpenApp is called to set App Group flags, trigger tactile haptics,
//     and cleanly dismiss the extension after allowing SpringBoard time to bring InkSync Pro forward.

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

        // ── Step 2: Tactile Feedback ──
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // ── Step 3: Dynamic Extension Context Open Fallback ──
        if let ext = extensionContext {
            let extOpenSel = NSSelectorFromString("openURL:completionHandler:")
            if ext.responds(to: extOpenSel) {
                typealias ExtOpenMethod = @convention(c) (NSObject, Selector, NSURL, ((Bool) -> Void)?) -> Void
                if let imp = ext.method(for: extOpenSel) {
                    let fn = unsafeBitCast(imp, to: ExtOpenMethod.self)
                    fn(ext, extOpenSel, deepLinkURL as NSURL, nil)
                }
            }
        }

        // ── Step 4: Graceful Handover Teardown ──
        // SwiftUI Link initiates SpringBoard app-switching. We wait 200ms to allow the transition
        // to complete before completing the extension request, preventing premature cancellation.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.completeHostAppHandover()
        }
    }
}

