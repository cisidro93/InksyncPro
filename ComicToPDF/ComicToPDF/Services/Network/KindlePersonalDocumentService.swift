import Foundation
import UIKit
import MessageUI
import SwiftUI

@MainActor
class KindlePersonalDocumentService: NSObject, ObservableObject, MFMailComposeViewControllerDelegate {
    static let shared = KindlePersonalDocumentService()
    
    @Published var isPresentingMail = false
    @Published var isPresentingShare = false
    
    var fileURLToSend: URL?
    var kindleEmail: String?
    var fileQueue: [URL] = []
    
    private override init() {
        super.init()
    }
    
    func send(fileURL: URL, kindleEmail: String?) async throws {
        self.fileURLToSend = fileURL
        self.kindleEmail = kindleEmail
        self.fileQueue = []
        
        // 1. Check if Kindle app is installed via scheme
        let kindleAppScheme = URL(string: "kindle://")!
        let canOpenKindle = UIApplication.shared.canOpenURL(kindleAppScheme)
        
        if canOpenKindle {
            // Priority 1: Share Extension (Requires UIActivityViewController)
            // Handled via EInkSendSheet pushing `isPresentingShare = true`
            self.isPresentingShare = true
        } else if MFMailComposeViewController.canSendMail() {
            // Priority 2: Mail Compose Fallback
            guard let email = kindleEmail, !email.isEmpty else {
                throw SendError.missingEmail
            }
            
            let ext = fileURL.pathExtension.lowercased()
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let rawFileSize = fileAttributes?[.size] as? Int64 ?? 0
            
            // If it's a large PDF, split it into parts to stay under the 24MB attachment limit
            if ext == "pdf" && rawFileSize > 24 * 1024 * 1024 {
                let parts = Self.splitPDF(at: fileURL, maxSizeBytes: 24 * 1024 * 1024)
                if parts.count > 1 {
                    self.fileQueue = parts
                    self.fileURLToSend = self.fileQueue.removeFirst()
                    Logger.shared.log("KindlePersonalDocumentService: PDF size \(rawFileSize / 1024 / 1024)MB exceeds limit. Split into \(parts.count) parts.", category: "NetworkSync", type: .info)
                }
            }
            
            self.isPresentingMail = true
        } else {
            // Priority 3: Manual Instructions
            throw SendError.noDeliveryMethod
        }
    }
    
    static func splitPDF(at url: URL, maxSizeBytes: Int64 = 24 * 1024 * 1024) -> [URL] {
        guard let doc = PDFDocument(url: url) else { return [url] }
        let pageCount = doc.pageCount
        guard pageCount > 1 else { return [url] }
        
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let rawFileSize = fileAttributes?[.size] as? Int64 ?? 0
        guard rawFileSize > maxSizeBytes else { return [url] }
        
        // Calculate number of parts needed
        let partsCount = max(2, Int(ceil(Double(rawFileSize) / Double(maxSizeBytes))))
        let pagesPerPart = max(1, Int(ceil(Double(pageCount) / Double(partsCount))))
        
        var splitURLs: [URL] = []
        let baseName = url.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
        
        for partIdx in 0..<partsCount {
            let startPage = partIdx * pagesPerPart
            let endPage = min(startPage + pagesPerPart, pageCount)
            guard startPage < endPage else { break }
            
            let partDoc = PDFDocument()
            for pageIdx in startPage..<endPage {
                if let page = doc.page(at: pageIdx) {
                    partDoc.insert(page, at: partDoc.pageCount)
                }
            }
            
            let partURL = tempDir.appendingPathComponent("\(baseName)_Part\(partIdx + 1).pdf")
            try? FileManager.default.removeItem(at: partURL)
            if partDoc.write(to: partURL) {
                splitURLs.append(partURL)
            }
        }
        
        return splitURLs.isEmpty ? [url] : splitURLs
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
    @Environment(\.dismiss) private var dismiss
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var parent: MailComposeView
        let dismissAction: DismissAction
        
        init(_ parent: MailComposeView, dismissAction: DismissAction) {
            self.parent = parent
            self.dismissAction = dismissAction
        }
        
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            let action = dismissAction
            Task { @MainActor in
                action()
                
                // If there are more parts queued up, present the next part controller sequentially
                let service = KindlePersonalDocumentService.shared
                if !service.fileQueue.isEmpty {
                    try? await Task.sleep(nanoseconds: 600_000_000) // allow transition animation
                    service.fileURLToSend = service.fileQueue.removeFirst()
                    service.isPresentingMail = true
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self, dismissAction: dismiss) }
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([toEmail])
        vc.setSubject("Send to Kindle")
        
        // 🚨 COMPETITOR HARDENING: Prevent loading a massive payload completely into RAM
        // Apple Mail and standard SMTP providers cap attachments at ~25MB.
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let rawFileSize = fileAttributes?[.size] as? Int64 ?? 0
        let isSafeSize = rawFileSize <= (24 * 1024 * 1024)
        
        if isSafeSize, let data = try? Data(contentsOf: fileURL) {
            let ext = fileURL.pathExtension.lowercased()
            let mimeType = ext == "epub" ? "application/epub+zip" : "application/pdf"
            vc.addAttachmentData(data, mimeType: mimeType, fileName: fileURL.lastPathComponent)
        } else if !isSafeSize {
            // Warn the user directly in the email body that the file was too large
            vc.setMessageBody("⚠️ Error: The file \(fileURL.lastPathComponent) (\(rawFileSize / 1024 / 1024) MB) exceeds the 25MB email attachment limit. Please use the 'Send to Kindle' website for files up to 200MB.", isHTML: false)
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
