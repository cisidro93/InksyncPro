import SwiftUI

struct BatchRenameView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var pattern = "{series} - #{issue}"
    @State private var startNumber = 1
    @State private var selectedFiles: Set<UUID> = []
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Rename Pattern")) {
                    TextField("Pattern (e.g., {series} #{issue})", text: $pattern)
                    Stepper("Start Number: \(startNumber)", value: $startNumber)
                    
                    Text("Available Tags: {series}, {issue}, {title}, {author}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Preview")) {
                    if let first = conversionManager.convertedPDFs.first {
                        Text(previewName(for: first))
                            .foregroundColor(.blue)
                    }
                }
                
                Section(header: Text("Select Files")) {
                    List {
                        ForEach(conversionManager.convertedPDFs) { pdf in
                            HStack {
                                Image(systemName: selectedFiles.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedFiles.contains(pdf.id) ? .blue : .gray)
                                Text(pdf.name)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedFiles.contains(pdf.id) {
                                    selectedFiles.remove(pdf.id)
                                } else {
                                    selectedFiles.insert(pdf.id)
                                }
                            }
                        }
                    }
                }
                
                Button("Rename \(selectedFiles.count) Files") {
                    performRename()
                }
                .disabled(selectedFiles.isEmpty)
            }
            .navigationTitle("Batch Rename")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
    
    func previewName(for pdf: ConvertedPDF) -> String {
        var name = pattern
        // ✅ Fix: Coalesce optionals to empty strings
        name = name.replacingOccurrences(of: "{series}", with: pdf.metadata.series ?? "Series")
        name = name.replacingOccurrences(of: "{issue}", with: pdf.metadata.issueNumber ?? "\(startNumber)")
        name = name.replacingOccurrences(of: "{title}", with: pdf.metadata.title)
        name = name.replacingOccurrences(of: "{author}", with: pdf.metadata.author ?? "Unknown")
        return name + "." + pdf.url.pathExtension
    }
    
    func performRename() {
        // Implementation stub for now
        dismiss()
    }
}
