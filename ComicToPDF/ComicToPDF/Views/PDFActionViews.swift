import SwiftUI

struct PDFActionViews: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingShareSheet = false
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        Menu {
            // Section 1: Read/Open
            Button {
                showingShareSheet = true
            } label: {
                Label("Export / Send to Kindle", systemImage: "square.and.arrow.up")
            }
            
            // Section 2: Tools
            Button {
                conversionManager.generateCoverThumbnail(for: pdf) // Refresh thumb
                // Trigger the "Extract Panels" editor (Cover Mode)
                if let image = conversionManager.getThumbnail(for: pdf) {
                    let session = PanelEditSession(id: UUID(), originalImage: image, panels: [])
                    conversionManager.currentPanelSession = session
                    conversionManager.showingPanelEditor = true
                }
            } label: {
                Label("Extract Panels (Cover)", systemImage: "scissors")
            }
            
            // Section 3: Destructive
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .padding(8)
        }
        // Sheets
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [pdf.url])
        }
        .alert("Delete File?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                conversionManager.deletePDF(pdf)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }
}
