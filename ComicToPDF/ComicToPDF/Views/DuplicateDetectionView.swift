import SwiftUI

struct DuplicateDetectionView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var duplicateGroups: [DuplicateGroup] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Scanning for duplicates...")
            } else if duplicateGroups.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("No Duplicates Found").font(.title2).bold()
                    Text("Your library is clean!").foregroundColor(.secondary)
                }
            } else {
                duplicateList
            }
        }
        .navigationTitle("Duplicate Finder")
        .task {
            duplicateGroups = await conversionManager.findDuplicates()
            isLoading = false
        }
    }
    
    var duplicateList: some View {
        List {
            ForEach(duplicateGroups) { group in
                Section(header: Text("Identical Files (\(group.pdfs.count))")) {
                    ForEach(group.pdfs) { pdf in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pdf.name).font(.headline)
                                Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                deletePDF(pdf)
                            }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        withAnimation {
            conversionManager.removeFromLibrary(pdf)
            // Refresh list if needed
        }
    }
}
