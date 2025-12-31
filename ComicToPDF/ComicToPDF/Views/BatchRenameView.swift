import SwiftUI

struct BatchRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var pattern: String = "Vol {n} - {series}"
    @State private var startNumber: Int = 1
    @State private var selectedPDFs: Set<UUID> = []
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Selection")) {
                    Text("Selected: \(selectedPDFs.count) PDFs")
                }
                
                Section(header: Text("Pattern")) {
                    TextField("Pattern", text: $pattern)
                    Text("Available placeholders: {n}, {name}, {series}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Stepper("Start Number: \(startNumber)", value: $startNumber)
                }
                
                Section(header: Text("Preview")) {
                    if let first = conversionManager.convertedPDFs.first(where: { selectedPDFs.contains($0.id) }) {
                        let preview = pattern.replacingOccurrences(of: "{n}", with: "\(startNumber)")
                            .replacingOccurrences(of: "{name}", with: first.name)
                            .replacingOccurrences(of: "{series}", with: first.metadata.series)
                        Text(preview)
                            .foregroundColor(.blue)
                    }
                }
                
                Button("Rename All") {
                    let pdfs = conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
                    conversionManager.batchRename(pdfs: pdfs, pattern: pattern, startNumber: startNumber)
                    dismiss()
                }
                .disabled(selectedPDFs.isEmpty)
            }
            .navigationTitle("Batch Rename")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
