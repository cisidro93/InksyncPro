import SwiftUI

struct FileMergeView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedIDs: Set<UUID> = []
    @State private var mergedName: String = ""
    
    var body: some View {
        NavigationView {
            VStack {
                TextField("Collection Name (e.g. Omnibus Vol 1)", text: $mergedName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                
                List(conversionManager.convertedPDFs, id: \.id) { pdf in
                    HStack {
                        Image(systemName: selectedIDs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedIDs.contains(pdf.id) ? .blue : .gray)
                        Text(pdf.name)
                        Spacer()
                        Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIDs.contains(pdf.id) {
                            selectedIDs.remove(pdf.id)
                        } else {
                            selectedIDs.insert(pdf.id)
                        }
                    }
                }
                
                Button(action: {
                    let selectedFiles = conversionManager.convertedPDFs.filter { selectedIDs.contains($0.id) }
                    Task {
                        await conversionManager.mergePDFs(selectedFiles, outputName: mergedName)
                        dismiss()
                    }
                }) {
                    HStack {
                        if conversionManager.isConverting { ProgressView().padding(.trailing, 5) }
                        Text("Merge \(selectedIDs.count) Files")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(selectedIDs.count < 2 ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(selectedIDs.count < 2 || conversionManager.isConverting)
                .padding()
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
