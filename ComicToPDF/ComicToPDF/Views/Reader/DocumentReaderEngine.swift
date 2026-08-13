import SwiftUI
@preconcurrency import PDFKit
import PencilKit

/// Delegation wrapper routing legacy DocumentReaderEngine invocations directly to ProPDFReaderEngine
struct DocumentReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void
    
    var body: some View {
        ProPDFReaderEngine(pdf: pdf, onDismiss: onDismiss)
    }
}
