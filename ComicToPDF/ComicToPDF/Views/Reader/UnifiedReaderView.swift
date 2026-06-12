import SwiftUI

struct UnifiedReaderView: View {
    let pdf: ConvertedPDF
    /// All books in the library — used for series-end continuation (next volume).
    var allBooks: [ConvertedPDF] = []
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").edgesIgnoringSafeArea(.all)
            
            switch pdf.contentType {
            case .comic, .manga:
                ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
            case .book:
                BookReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
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
