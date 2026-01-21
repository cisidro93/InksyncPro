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

struct ComicCoverLoader: View {
    let url: URL
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
        .onAppear {
            loadCover()
        }
    }
    
    private func loadCover() {
        if let cached = conversionManager.thumbnailCache.object(forKey: url.path as NSString) {
            self.image = cached
        } else {
             // Fallback: Try to use the coverImageData from PDF if available (fastest)
             // We can find the PDF object in conversionManager lists if needed, but 'url' is our key.
             // Actually, the calling view 'EditorRowView' has the 'pdf' object. 
             // Ideally we pass the whole PDF, but URL is what we have here.
             // We will try a background extraction if cache miss.
             
             Task {
                 if let existingPDF = conversionManager.convertedPDFs.first(where: { $0.url == url }),
                    let data = existingPDF.coverImageData,
                    let uiImage = UIImage(data: data) {
                     await MainActor.run {
                         self.image = uiImage
                         conversionManager.thumbnailCache.setObject(uiImage, forKey: url.path as NSString)
                     }
                     return
                 }
                 
                 // If no data, try extracting
                 let generated = await Task.detached {
                      return ConversionManager.extractCoverImageStatic(from: url)
                 }.value
                 
                 if let generated {
                     await MainActor.run {
                         self.image = generated
                         conversionManager.thumbnailCache.setObject(generated, forKey: url.path as NSString)
                     }
                 }
             }
        }
    }
}
