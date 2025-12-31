import SwiftUI

struct PDFMergeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedPDFs: Set<UUID> = []
    @State private var outputName: String = "Merged Doc"
    @State private var isMerging = false
    
    var body: some View {
        NavigationView {
            VStack {
                Form {
                    Section(header: Text("Settings")) {
                        TextField("Output Name", text: $outputName)
                    }
                    
                    Section(header: Text("Select PDFs to Merge")) {
                        List {
                            ForEach(conversionManager.convertedPDFs) { pdf in
                                HStack {
                                    Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedPDFs.contains(pdf.id) ? .blue : .secondary)
                                    Text(pdf.name)
                                    Spacer()
                                    Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedPDFs.contains(pdf.id) {
                                        selectedPDFs.remove(pdf.id)
                                    } else {
                                        selectedPDFs.insert(pdf.id)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Button(action: mergeFiles) {
                    if isMerging {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("Merge \(selectedPDFs.count) Files")
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedPDFs.count < 2 ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .disabled(selectedPDFs.count < 2 || isMerging)
                .padding()
            }
            .navigationTitle("Merge PDFs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func mergeFiles() {
        guard !outputName.isEmpty else { return }
        isMerging = true
        
        let pdfsToMerge = conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
        
        Task {
            do {
                let url = try await conversionManager.mergePDFs(pdfsToMerge, outputName: outputName)
                await MainActor.run {
                    conversionManager.addToLibrary(url)
                    isMerging = false
                    dismiss()
                }
            } catch {
                print("Merge failed: \(error)")
                await MainActor.run { isMerging = false }
            }
        }
    }
}
