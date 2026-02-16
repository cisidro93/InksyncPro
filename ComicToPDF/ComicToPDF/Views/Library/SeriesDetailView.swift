import SwiftUI

struct SeriesDetailView: View {
    let series: SeriesGroup
    @EnvironmentObject var conversionManager: ConversionManager
    
    // We reuse LibraryView's navigation links logic by passing selected PDF up?
    // Or we just replicate the navigation link to ConvertView/PageManager.
    
    @State private var sortOrder: SortOrder = .ascending
    
    enum SortOrder {
        case ascending, descending
    }
    
    var sortedIssues: [ConvertedPDF] {
        let issues = series.issues
        return sortOrder == .ascending ? issues : issues.reversed()
    }
    
    var body: some View {
        List {
            Section(header: headerView) {
                ForEach(sortedIssues) { pdf in
                    NavigationLink(destination: ConvertView(pdf: pdf)) {
                        LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            conversionManager.deletePDF(pdf)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(series.title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        Text("Oldest First").tag(SortOrder.ascending)
                        Text("Newest First").tag(SortOrder.descending)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
    }
    
    var headerView: some View {
        HStack {
            if let data = series.cover, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .cornerRadius(8)
                    .shadow(radius: 4)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 120)
                    .overlay(Image(systemName: "books.vertical").foregroundColor(.gray))
                    .cornerRadius(8)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.title2)
                    .bold()
                    .foregroundColor(.primary)
                
                Text("\(series.count) Issues")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let publisher = series.issues.first?.metadata.publisher {
                    Text(publisher)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.top, 4)
                }
            }
            .padding(.leading)
            
            Spacer()
        }
        .padding(.vertical)
    }
}
