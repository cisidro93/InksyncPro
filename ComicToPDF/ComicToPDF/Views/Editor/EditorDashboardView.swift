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
                        // ✅ Phase 31 Zettelkasten Hub Anchor
                        NavigationLink(destination: GlobalZettelkastenHubView()) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Zettelkasten Hub")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text("Global Reading Highlights & Notes")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                Spacer()
                                Image(systemName: "sparkles.rectangle.stack.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            .padding()
                            .background(
                                LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .cornerRadius(12)
                            .shadow(color: Color.blue.opacity(0.3), radius: 5, x: 0, y: 3)
                        }
                        
                        // Book Instances
                        ForEach(filteredPDFs) { pdf in
                            EditorRowView(pdf: pdf) {
                                if pdf.contentType == .book {
                                    // Books skip image extraction and go straight to Metadata editing
                                    selectedBookForMetadata = pdf
                                } else {
                                    selectedPDF = pdf
                                }
                            }
                        }
                    }
                    .padding()
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
                // Cover
               ComicCoverLoader(pdf: pdf)
                    .frame(width: 60, height: 90)
                    .cornerRadius(8)
                    .shadow(radius: 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(pdf.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    HStack(spacing: 6) {
                        // Content Type Badge
                        HStack(spacing: 4) {
                            Image(systemName: pdf.contentType.icon)
                                .font(.caption2)
                            Text(pdf.contentType.rawValue)
                                .font(.caption2)
                                .bold()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pdf.contentType.badgeColor)
                        .cornerRadius(4)
                        
                        Text("\(pdf.pageCount) Pages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
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
