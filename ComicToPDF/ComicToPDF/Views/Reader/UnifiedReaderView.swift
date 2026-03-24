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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
