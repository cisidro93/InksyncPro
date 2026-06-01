import SwiftUI

struct EditorDashboardView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var focusManager = WorkspaceFocusManager.shared
    @State private var searchText = ""
    @State private var selectedPDF: ConvertedPDF?
    @State private var selectedBookForMetadata: ConvertedPDF?
    
    var filteredPDFs: [ConvertedPDF] {
        let pinnedPDFs = conversionManager.convertedPDFs.filter { focusManager.pinnedIDs.contains($0.id) }
        
        if searchText.isEmpty {
            return pinnedPDFs
        } else {
            return pinnedPDFs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            if filteredPDFs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 60))
                        .foregroundStyle(Color.inkTextSecondary)
                    Text("No Files in Work Area")
                        .font(.title2.bold())
                        .foregroundStyle(Color.inkTextPrimary)
                    Text("Long-press a file in the Library tab and tap \"Send to Work Area\" to start editing.")
                        .foregroundStyle(Color.inkTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("SwitchToLibraryTab"), object: nil)
                    }) {
                        Text("Go to Library")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.inkAccentKnowledge)
                            .cornerRadius(8)
                    }
                    .padding(.top, 10)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: InkSpacing.rowGap) {
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
                .inkTabBarScrollDetect()
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
        .contextMenu {
            Button(role: .destructive) {
                WorkspaceFocusManager.shared.unpin(pdf)
            } label: {
                Label("Remove from Work Area", systemImage: "pin.slash")
            }
        }
    }
}

struct ComicCoverLoader: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var image: UIImage?

    private var isCloud: Bool {
        if case .cloud = pdf.sourceMode { return true }
        return false
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                    VStack(spacing: 6) {
                        Image(systemName: isCloud ? "icloud.and.arrow.down" : "photo")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                        if isCloud {
                            Text("Cloud")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                        }
                    }
                }
            }
        }
        .task {
            // 1. Try in-memory + disk cache first
            if image == nil {
                image = await conversionManager.loadCoverThumbnail(for: pdf)
            }
            // 2. If still nil and it's a cloud file, kick off background byte-range extraction
            if image == nil, isCloud {
                await CloudCoverExtractor.shared.extract(for: [pdf])
            }
        }
        // 3. Observe async extraction completion — refresh this cell when the cover arrives
        .onReceive(NotificationCenter.default.publisher(for: .cloudCoverReady)) { note in
            guard let pdfID = note.userInfo?["pdfID"] as? UUID,
                  pdfID == pdf.id,
                  let newImage = note.userInfo?["image"] as? UIImage else { return }
            withAnimation(.easeIn(duration: 0.3)) { image = newImage }
        }
    }
}
