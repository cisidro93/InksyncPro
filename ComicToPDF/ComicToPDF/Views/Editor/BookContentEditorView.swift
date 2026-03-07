import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation
import PDFKit

struct BookContentEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    var pdf: ConvertedPDF
    
    var body: some View {
        NavigationStack {
            if pdf.url.pathExtension.lowercased() == "pdf" {
                PDFContentEditorView(pdf: pdf)
            } else if pdf.url.pathExtension.lowercased() == "epub" {
                EPUBContentEditorView(pdf: pdf)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Unsupported Format")
                        .font(.headline)
                    Text("Only PDF and EPUB books support structural editing.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }
}
