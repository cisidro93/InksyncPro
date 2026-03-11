import SwiftUI

// MARK: - PageExtractionView
struct PageExtractionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @State private var rangeStart: Int = 1
    @State private var rangeEnd: Int = 1
    @State private var exportAsImages = false
    @State private var isExporting = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Page Range")) {
                    Stepper("Start Page: \(rangeStart)", value: $rangeStart, in: 1...pdf.pageCount)
                    Stepper("End Page: \(rangeEnd)", value: $rangeEnd, in: 1...pdf.pageCount)
                    
                    Text("Total Pages: \(pdf.pageCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Format")) {
                    Toggle("Export as Images (JPEG)", isOn: $exportAsImages)
                }
                
                Section {
                    Button(action: extract) {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text("Extract Pages")
                                .bold()
                                .foregroundColor(.blue)
                        }
                    }
                    .disabled(isExporting || rangeStart > rangeEnd)
                }
            }
            .navigationTitle("Extract Pages")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func extract() {
        guard rangeStart <= rangeEnd else { return }
        isExporting = true
        
        let range = Array((rangeStart-1)...(rangeEnd-1))
        Task {
            do {
                let _ = try await conversionManager.extractPages(from: pdf, pageIndices: range, asImages: exportAsImages)
                await MainActor.run {
                    isExporting = false
                    // Optionally show result alert or share sheet
                    dismiss()
                }
            } catch {
                print("Extraction failed: \(error)")
                await MainActor.run { isExporting = false }
            }
        }
    }
}

// MARK: - PanelExtractionView
struct PanelExtractionView: View {
    let sourceImage: UIImage
    @Binding var isPresented: Bool
    @State private var extractedImages: [UIImage] = []
    @State private var isProcessing = false
    @State private var mode: PanelExtractor.ExtractionMode = .automatic
    
    var body: some View {
        NavigationView {
            VStack {
                if extractedImages.isEmpty {
                    Image(uiImage: sourceImage)
                        .resizable()
                        .scaledToFit()
                        .overlay(isProcessing ? ProgressView() : nil)
                } else {
                    List(extractedImages, id: \.self) { img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                    }
                }
            }
            .navigationTitle("Extract Panels")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Extract") {
                        extract()
                    }
                    .disabled(isProcessing)
                }
            }
        }
    }
    
    func extract() {
        isProcessing = true
        Task {
            // ✅ Fix: Use the method that returns UIImages
            let images = try? await PanelExtractor.extractPanels(from: sourceImage, mode: mode)
            await MainActor.run {
                self.extractedImages = images ?? []
                self.isProcessing = false
            }
        }
    }
}
