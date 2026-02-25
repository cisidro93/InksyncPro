import SwiftUI

struct SeriesLibraryView: View {
    @StateObject private var viewModel: SeriesViewModel
    @EnvironmentObject var conversionManager: ConversionManager

    let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]

    init(conversionManager: ConversionManager) {
        _viewModel = StateObject(wrappedValue: SeriesViewModel(manager: conversionManager))
    }

    /// Files that have no series — shown as a flat list below the series grid
    var ungroupedFiles: [ConvertedPDF] {
        conversionManager.visiblePDFs.filter {
            $0.metadata.series == nil || ($0.metadata.series?.isEmpty ?? true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Series Grid
                if !viewModel.seriesGroups.isEmpty {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(viewModel.seriesGroups) { group in
                            NavigationLink(destination: SeriesDetailView(series: group, selectedPDF: .constant(nil), useNavigationStack: true)) {
                                SeriesCard(group: group)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                }

                // MARK: Ungrouped Files Section
                if !ungroupedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("Ungrouped Files")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(ungroupedFiles.count)")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.gray)
                                .cornerRadius(8)
                        }
                        .padding(.horizontal)
                        .padding(.top, viewModel.seriesGroups.isEmpty ? 16 : 28)
                        .padding(.bottom, 8)

                        Divider().padding(.horizontal)

                        ForEach(ungroupedFiles) { pdf in
                            NavigationLink(destination: ConvertView(pdf: pdf)) {
                                LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }

                // MARK: Empty State
                if viewModel.seriesGroups.isEmpty && ungroupedFiles.isEmpty {
                    emptyState
                }

                Spacer(minLength: 80) // FAB clearance
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.5))
            Text("No Series Found")
                .font(.headline)
                .foregroundColor(.primary)
            Text("When you import multiple issues from the same series,\nthey'll be grouped here automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - Series Card

struct SeriesCard: View {
    let group: SeriesGroup
    @State private var coverImage: UIImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover stack
            ZStack(alignment: .bottomLeading) {
                coverStack
                // Issue count badge — bottom-left corner
                Text("\(group.count) issues")
                    .font(.caption2).bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(6)
                    .padding(8)
            }
            .frame(height: 220)
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.18), radius: 4, x: 2, y: 2)

            // Title
            Text(group.title)
                .font(.subheadline).fontWeight(.semibold)
                .lineLimit(2)
                .foregroundColor(.primary)
                .padding(.top, 8)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .task { await loadCover() }
    }

    @ViewBuilder
    var coverStack: some View {
        ZStack {
            // Stack shadow layers
            if group.count > 2 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.tertiarySystemBackground))
                    .frame(height: 220)
                    .offset(x: 7, y: -7)
                    .scaleEffect(0.9)
            }
            if group.count > 1 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: 220)
                    .offset(x: 3.5, y: -3.5)
                    .scaleEffect(0.95)
            }
            // Front cover
            if let img = coverImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 220)
                    .clipped()
            } else {
                // Placeholder
                ZStack {
                    Rectangle()
                        .fill(Color(UIColor.secondarySystemBackground))
                    VStack(spacing: 8) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.gray.opacity(0.4))
                        Text(group.title)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(height: 220)
            }
        }
    }

    private func loadCover() async {
        guard let url = group.coverURL else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return UIImage?.none }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 200, height: 300))
        }.value
        await MainActor.run { coverImage = loaded }
    }
}
