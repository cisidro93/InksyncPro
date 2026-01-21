import SwiftUI

struct EditorDashboardView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var searchText = ""
    @State private var selectedPDF: ConvertedPDF?
    
    var filteredPDFs: [ConvertedPDF] {
        if searchText.isEmpty {
            return conversionManager.convertedPDFs
        } else {
            return conversionManager.convertedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all)
                
                if filteredPDFs.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "pencil.and.outline")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Comics to Edit")
                            .font(.title2)
                            .bold()
                        Text("Import comics in the Library tab to start editing.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(filteredPDFs) { pdf in
                                EditorRowView(pdf: pdf) {
                                    selectedPDF = pdf
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Work Area")
            .searchable(text: $searchText, prompt: "Search comics...")
            .fullScreenCover(item: $selectedPDF) { pdf in
                PageManagerView(pdf: pdf)
            }
        }
    }
}

struct EditorRowView: View {
    let pdf: ConvertedPDF
    let action: () -> Void
    @EnvironmentObject var conversionManager: ConversionManager
    
    var editedPageCount: Int {
        conversionManager.panelOverrides[pdf.id]?.count ?? 0
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Cover
               ComicCoverLoader(url: pdf.url)
                    .frame(width: 60, height: 90)
                    .cornerRadius(8)
                    .shadow(radius: 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(pdf.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    Text("\(pdf.pageCount) Pages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if editedPageCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.caption2)
                            Text("\(editedPageCount) pages with Guided View")
                                .font(.caption2)
                                .bold()
                        }
                        .foregroundColor(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(4)
                    } else {
                        Text("No Guided View data")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
    }
}
