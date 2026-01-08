import SwiftUI

struct PDFActionViews: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    var body: some View {
        HStack {
            Button(action: {
                // ✅ Fix: Wrap async call in Task
                Task {
                    await conversionManager.convertComic(pdf, mangaMode: false)
                }
            }) {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            
            Button(role: .destructive, action: {
                conversionManager.deletePDF(pdf)
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
