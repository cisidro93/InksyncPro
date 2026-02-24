import SwiftUI

struct SeriesDetailView: View {
    let series: SeriesGroup
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var sortOrder: SortOrder = .ascending
    @State private var headerCover: UIImage? = nil

    enum SortOrder { case ascending, descending }

    var sortedIssues: [ConvertedPDF] {
        sortOrder == .ascending ? series.issues : series.issues.reversed()
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
        .task { await loadHeaderCover() }
    }

    var headerView: some View {
        HStack {
            if let img = headerCover {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(width: 80, height: 120)
                    .overlay(Image(systemName: "books.vertical").foregroundColor(.gray))
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.title2).bold()
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

    private func loadHeaderCover() async {
        guard let url = series.coverURL else { return }
        let img = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return UIImage?.none }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 160, height: 240))
        }.value
        await MainActor.run { headerCover = img }
    }
}

