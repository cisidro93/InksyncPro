import SwiftUI

struct UnifiedReaderView: View {
    let pdf: ConvertedPDF
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").edgesIgnoringSafeArea(.all)
            
            switch pdf.contentKind {
            case .comic:
                ComicReaderEngine(pdf: pdf, onDismiss: { presentationMode.wrappedValue.dismiss() })
            case .book:
                BookReaderEngine(pdf: pdf, onDismiss: { presentationMode.wrappedValue.dismiss() })
            case .document:
                DocumentReaderEngine(pdf: pdf, onDismiss: { presentationMode.wrappedValue.dismiss() })
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: true)
    }
}

// Engines will be built in their respective files.

// Removed duplicate Color extension
