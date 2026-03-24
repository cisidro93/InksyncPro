import Foundation
import UIKit
import MessageUI

@MainActor
class KindlePersonalDocumentService: NSObject, ObservableObject, MFMailComposeViewControllerDelegate {
    static let shared = KindlePersonalDocumentService()
    
    @Published var isPresentingMail = false
    @Published var isPresentingShare = false
    
    var fileURLToSend: URL?
    var kindleEmail: String?
    
    // UIViewController presenting reference would normally be injected.
    // In SwiftUI, we create a representable for MailCompose.
    
    private override init() {
        super.init()
    }
    
    func send(fileURL: URL, kindleEmail: String?) async throws {
        self.fileURLToSend = fileURL
        self.kindleEmail = kindleEmail
        
        // 1. Check if Kindle app is installed via scheme
        let kindleAppScheme = URL(string: "kindle://")!
        let canOpenKindle = UIApplication.shared.canOpenURL(kindleAppScheme)
        
        if canOpenKindle {
            // Priority 1: Share Extension (Requires UIActivityViewController)
            // Handled via EInkSendSheet pushing `isPresentingShare = true`
            self.isPresentingShare = true
        } else if MFMailComposeViewController.canSendMail() {
            // Priority 2: Mail Compose Fallback
            guard kindleEmail != nil && !kindleEmail!.isEmpty else {
                throw SendError.missingEmail
            }
            self.isPresentingMail = true
        } else {
            // Priority 3: Manual Instructions
            throw SendError.noDeliveryMethod
        }
    }
    
    enum SendError: LocalizedError {
        case missingEmail
        case noDeliveryMethod
        
        var errorDescription: String? {
            switch self {
            case .missingEmail: return "Kindle email address is required for Mail fallback."
            case .noDeliveryMethod: return "Cannot send to Kindle. Please install the Kindle app or configure Apple Mail."
            }
        }
    }
}

// SwiftUI Wrapper for Mail
struct MailComposeView: UIViewControllerRepresentable {
    let fileURL: URL
    let toEmail: String
    @Environment(\.presentationMode) var presentationMode
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var parent: MailComposeView
        init(_ parent: MailComposeView) { self.parent = parent }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([toEmail])
        vc.setSubject("Send to Kindle")
        
        if let data = try? Data(contentsOf: fileURL) {
            let ext = fileURL.pathExtension.lowercased()
            let mimeType = ext == "epub" ? "application/epub+zip" : "application/pdf"
            vc.addAttachmentData(data, mimeType: mimeType, fileName: fileURL.lastPathComponent)
        }
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
}

// SwiftUI Wrapper for UIActivityViewController
struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        // Try to hint to Kindle if possible, but iOS share sheets are opaque.
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
