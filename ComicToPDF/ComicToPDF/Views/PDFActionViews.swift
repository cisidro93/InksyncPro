import SwiftUI

struct PDFActionViews: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var showingExtraction = false
    @State private var newName = ""
    
    var body: some View {
        Menu {
            Button {
                newName = pdf.name
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            Button {
                showingExtraction = true
            } label: {
                Label("Extract Panels", systemImage: "crop")
            }
            
            Divider()
            
            Button(role: .destructive) {
                showingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .padding(8)
        }
        // Rename Alert
        .alert("Rename File", isPresented: $showingRename) {
            TextField("New Name", text: $newName)
            Button("Rename") {
                // Rename logic stub
            }
            Button("Cancel", role: .cancel) { }
        }
        // Delete Alert
        .alert("Delete File", isPresented: $showingDelete) {
            Button("Delete", role: .destructive) {
                conversionManager.deletePDF(pdf)
            }
            Button("Cancel", role: .cancel) { }
        }
        // Extraction Sheet
        .sheet(isPresented: $showingExtraction) {
            if let thumbnail = conversionManager.getThumbnail(for: pdf) {
                // ✅ FIX: Passed 'isPresented' binding
                PanelExtractionView(sourceImage: thumbnail, isPresented: $showingExtraction)
            } else {
                Text("No image available")
            }
        }
    }
}
