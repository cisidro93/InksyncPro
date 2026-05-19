import SwiftUI

struct UnifiedReaderView: View {
    let pdf: ConvertedPDF
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").edgesIgnoringSafeArea(.all)
            
            switch pdf.contentType {
            case .comic, .manga:
                ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() })
            case .book:
                BookReaderEngine(pdf: pdf, onDismiss: { dismiss() })
            case .hybrid:
                DocumentReaderEngine(pdf: pdf, onDismiss: { dismiss() })
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: true)
    }
}

// Engines will be built in their respective files.

// Removed duplicate Color extension
