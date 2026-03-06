import SwiftUI
import MessageUI

struct MailView: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentation
    var subject: String
    var toRecipients: [String]
    var attachments: [URL]
    var result: (Result<MFMailComposeResult, Error>) -> Void
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var presentation: PresentationMode
        var result: (Result<MFMailComposeResult, Error>) -> Void
        
        init(presentation: Binding<PresentationMode>,
             result: @escaping (Result<MFMailComposeResult, Error>) -> Void) {
            _presentation = presentation
            self.result = result
        }
        
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            defer { $presentation.wrappedValue.dismiss() }
            if let error = error {
                self.result(.failure(error))
            } else {
                self.result(.success(result))
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(presentation: presentation, result: result)
    }
    
    func makeUIViewController(context: UIViewControllerRepresentableContext<MailView>) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(subject)
        vc.setToRecipients(toRecipients)
        
        for url in attachments {
            if let data = try? Data(contentsOf: url) {
                let mimeType: String
                switch url.pathExtension.lowercased() {
                case "epub": mimeType = "application/epub+zip"
                case "pdf": mimeType = "application/pdf"
                case "cbz": mimeType = "application/x-cbz"
                default: mimeType = "application/octet-stream"
                }
                vc.addAttachmentData(data, mimeType: mimeType, fileName: url.lastPathComponent)
            }
        }
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController,
                                context: UIViewControllerRepresentableContext<MailView>) {}
}
