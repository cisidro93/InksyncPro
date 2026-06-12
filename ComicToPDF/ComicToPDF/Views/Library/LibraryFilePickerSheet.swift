import SwiftUI

struct LibraryFilePickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var searchText = ""
    
    let onSelect: (ConvertedPDF) -> Void
    
    var filteredPDFs: [ConvertedPDF] {
        if searchText.isEmpty {
            return conversionManager.convertedPDFs.sorted { 
                let s1 = $0.metadata.series ?? ""
                let s2 = $1.metadata.series ?? ""
                if s1 == s2 {
                    // Include Issue Number in natural sorting if possible, otherwise Name
                    if let i1 = $0.metadata.issueNumber, let i2 = $1.metadata.issueNumber, let n1 = Int(i1), let n2 = Int(i2) {
                        return n1 < n2
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return s1 < s2
            }
        } else {
            let lowerQuery = searchText.lowercased()
            return conversionManager.convertedPDFs.filter { pdf in
                pdf.name.lowercased().contains(lowerQuery) ||
                (pdf.metadata.series?.lowercased().contains(lowerQuery) == true) ||
                (pdf.metadata.issueNumber?.lowercased().contains(lowerQuery) == true) ||
                (pdf.metadata.volume?.lowercased().contains(lowerQuery) == true)
            }.sorted { 
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
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
