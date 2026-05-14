import SwiftUI

struct EditorDashboardView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var searchText = ""
    @State private var selectedPDF: ConvertedPDF?
    @State private var selectedBookForMetadata: ConvertedPDF?
    
    var filteredPDFs: [ConvertedPDF] {
        if searchText.isEmpty {
            return conversionManager.convertedPDFs
        } else {
            return conversionManager.convertedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()

            if filteredPDFs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 60))
                        .foregroundStyle(Color.inkTextSecondary)
                    Text("No Comics to Edit")
                        .font(.title2.bold())
                        .foregroundStyle(Color.inkTextPrimary)
                    Text("Import comics in the Library tab to start editing.")
                        .foregroundStyle(Color.inkTextSecondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: InkSpacing.rowGap) {
                        // Zettelkasten Hub anchor card
                        NavigationLink(destination: GlobalZettelkastenHubView()) {
                            HStack(spacing: 14) {
                                // Icon badge
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.inkAccentKnowledge, Color.inkBlue],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "sparkles.rectangle.stack.fill")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Zettelkasten Hub")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.inkTextPrimary)
                                    Text("Global Reading Highlights & Notes")
                                        .font(.caption)
                                        .foregroundStyle(Color.inkTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.inkTextTertiary)
                            }
                            .padding(InkSpacing.cardPadding)
                            .inkCard()
                        }
                        .buttonStyle(.plain)

                        // Book Instances
                        ForEach(filteredPDFs) { pdf in
                            EditorRowView(pdf: pdf) {
                                if pdf.contentType == .book {
                                    selectedBookForMetadata = pdf
                                } else {
                                    selectedPDF = pdf
                                }
                            }
                        }
                    }
                    .padding(InkSpacing.pagePadding)
                }
            }
        }
        .navigationTitle("Work Area")
        .searchable(text: $searchText, prompt: "Search library...")
        .fullScreenCover(item: $selectedPDF) { pdf in
            PageManagerView(pdf: pdf)
        }
        .sheet(item: $selectedBookForMetadata) { pdf in
            MetadataEditorView(pdf: pdf)
        }
    }
}

struct EditorRowView: View {
    let pdf: ConvertedPDF
    let action: () -> Void
    @EnvironmentObject var conversionManager: ConversionManager
    
    var editedPageCount: Int {
        PageModelStore.shared.getEditedPageCount(for: pdf.id)
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ComicCoverLoader(pdf: pdf)
                    .frame(width: 58, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: InkRadius.thumbnail, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 5) {
                    Text(pdf.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.inkTextPrimary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: pdf.contentType.icon)
                                .font(.caption2)
                            Text(pdf.contentType.rawValue)
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pdf.contentType.badgeColor, in: RoundedRectangle(cornerRadius: InkRadius.badge, style: .continuous))

                        Text("\(pdf.pageCount) Pages")
                            .font(.caption)
                            .foregroundStyle(Color.inkTextSecondary)
                    }

                    if editedPageCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.caption2)
                            Text("\(editedPageCount) pages with Guided View")
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(Color.inkAccentKnowledge)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.inkAccentKnowledge.opacity(0.12), in: RoundedRectangle(cornerRadius: InkRadius.badge, style: .continuous))
                    } else {
                        Text("No Guided View data")
                            .font(.caption2)
                            .foregroundStyle(Color.inkTextTertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color.inkTextTertiary)
            }
            .padding(InkSpacing.cardPadding)
            .inkCard()
        }
    }
}

struct ComicCoverLoader: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let params = image {
                Image(uiImage: params)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            }
        }
        .task {
            if image == nil {
                image = await conversionManager.loadCoverThumbnail(for: pdf)
            }
        }
    }
}
