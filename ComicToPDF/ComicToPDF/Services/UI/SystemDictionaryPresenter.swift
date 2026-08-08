import UIKit
import SwiftUI

@MainActor
public final class SystemDictionaryPresenter {
    public static let shared = SystemDictionaryPresenter()
    private init() {}

    /// Presents native iOS system definition lookup for selected word or phrase.
    public func presentDefinition(for term: String) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else { return }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let refVC = UIReferenceLibraryViewController(term: cleanTerm)
        topVC.present(refVC, animated: true, completion: nil)
    }
}
