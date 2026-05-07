import Foundation
import AuthenticationServices
import UIKit

/// Minimal ASWebAuthenticationPresentationContextProviding conformer.
/// UIWindow itself IS an ASPresentationAnchor (typealias for UIWindow),
/// but it does NOT conform to ASWebAuthenticationPresentationContextProviding.
/// Wrapping it here is the correct pattern used by all first-party Apple samples.
final class OAuthWindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return window
    }
}
