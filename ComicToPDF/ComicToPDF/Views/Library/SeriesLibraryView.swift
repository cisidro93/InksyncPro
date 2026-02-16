import SwiftUI

struct SeriesLibraryView: View {
    @StateObject private var viewModel: SeriesViewModel
    @EnvironmentObject var conversionManager: ConversionManager
    
    let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]
    
    init(conversionManager: ConversionManager) {
        _viewModel = StateObject(wrappedValue: SeriesViewModel(manager: conversionManager))
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(viewModel.seriesGroups) { group in
                    NavigationLink(destination: SeriesDetailView(series: group)) {
                        SeriesCard(group: group)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding()
        }
        .overlay(Group {
            if viewModel.seriesGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No Series Found")
                        .font(.headline)
                    Text("Edit metadata to group comics by series.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        })
    }
}

struct SeriesCard: View {
    let group: SeriesGroup
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover Stack Effect
            ZStack {
                // Background Cards (Stack Effect)
                if group.count > 1 {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 220)
                        .offset(x: 4, y: -4)
                        .scaleEffect(0.95)
                }
                
                if group.count > 2 {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 220)
                        .offset(x: 8, y: -8)
                        .scaleEffect(0.9)
                }
                
                // Front Cover
                if let data = group.cover, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 220)
                        .cornerRadius(8)
                        .shadow(radius: 2)
                        .clipped() // Ensure crop
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(height: 220)
                        .overlay(Image(systemName: "book.closed").font(.largeTitle))
                        .cornerRadius(8)
                }
            }
            .frame(height: 220) // Constrain stack
            
            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                
                Text("\(group.count) Issues")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle()) // Hit test entire area
    }
}
