import SwiftUI

struct LibraryFilePickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var searchText = ""
    
    let onSelect: (ConvertedPDF) -> Void
    
    var filteredPDFs: [ConvertedPDF] {
        if searchText.isEmpty {
            return conversionManager.convertedPDFs.sorted { $0.metadata.series ?? "" < $1.metadata.series ?? "" }
        } else {
            let lowerQuery = searchText.lowercased()
            return conversionManager.convertedPDFs.filter { pdf in
                pdf.name.lowercased().contains(lowerQuery) ||
                (pdf.metadata.series?.lowercased().contains(lowerQuery) == true) ||
                (pdf.metadata.issueNumber?.lowercased().contains(lowerQuery) == true)
            }.sorted { $0.name < $1.name }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredPDFs) { pdf in
                    Button {
                        onSelect(pdf)
                        dismiss()
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            if let series = pdf.metadata.series, !series.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(series)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(pdf.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text(pdf.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            if let issue = pdf.metadata.issueNumber, !issue.isEmpty {
                                Text("#\(issue)")
                                    .font(.subheadline)
                                    .bold()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search by title, series, or issue...")
            .navigationTitle("Select File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
