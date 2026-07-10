import SwiftUI

@available(iOS 16.0, *)
struct MetadataSpreadsheetView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    // We bind to an array of items to allow in-place edits in the Table
    @State private var items: [ConvertedPDF]

    
    init(items: [ConvertedPDF]) {
        self._items = State(initialValue: items)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Info Banner
                HStack {
                    Image(systemName: "tablecells.fill.badge.ellipsis")
                        .font(.title2)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("Pro Grid Editor")
                            .font(.headline)
                        Text("Bulk edit metadata fields simultaneously.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                
                // The Table View
                Table($items) {
                    TableColumn("File Name") { $item in
                        TextField("File Name", text: $item.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 200, ideal: 300)
                    
                    TableColumn("Series") { $item in
                        TextField("Series", text: Binding(
                            get: { item.metadata.series ?? "" },
                            set: { item.metadata.series = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 150, ideal: 200)
                    
                    TableColumn("Issue") { $item in
                        TextField("Issue", text: Binding(
                            get: { item.metadata.issueNumber ?? "" },
                            set: { item.metadata.issueNumber = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                    }
                    .width(min: 60, ideal: 80, max: 100)
                    
                    TableColumn("Volume") { $item in
                        TextField("Volume", text: Binding(
                            get: { item.metadata.volume ?? "" },
                            set: { item.metadata.volume = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 100, ideal: 150)
                    
                    TableColumn("Publisher") { $item in
                        TextField("Publisher", text: Binding(
                            get: { item.metadata.publisher ?? "" },
                            set: { item.metadata.publisher = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 120, ideal: 150)
                    
                    TableColumn("Writer") { $item in
                        TextField("Writer", text: Binding(
                            get: { item.metadata.writer ?? "" },
                            set: { item.metadata.writer = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 120, ideal: 150)
                }
            }
            .navigationTitle("Grid Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save All") {
                        saveChanges()
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
    
    private func saveChanges() {
        for updatedItem in items {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == updatedItem.id }) {
                conversionManager.convertedPDFs[idx] = updatedItem
            }
        }
        conversionManager.saveLibrary()
    }
}
