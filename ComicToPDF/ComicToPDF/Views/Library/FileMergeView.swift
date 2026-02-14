import SwiftUI

struct FileMergeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedPDFs: Set<UUID> = []
    @State private var outputName: String = ""
    @State private var mangaMode: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Select Files")) {
                    List(conversionManager.convertedPDFs) { pdf in
                        HStack {
                            Text(pdf.name)
                            Spacer()
                            if selectedPDFs.contains(pdf.id) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
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
                
                Section(header: Text("Output")) {
                    TextField("Collection Name", text: $outputName)
                    Toggle("Manga Mode (RTL)", isOn: $mangaMode)
                }
                
                Button("Merge Files") {
                    let files = conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
                    Task {
                        await conversionManager.mergePDFs(files, outputName: outputName, mangaMode: mangaMode)
                        dismiss()
                    }
                }
                .disabled(selectedPDFs.count < 2)
            }
            .navigationTitle("Merge Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
