import SwiftUI

struct InboxReviewView: View {
    @EnvironmentObject var manager: ConversionManager
    
    // Derived subset of Library: Items lacking series or author (meaning they likely need review)
    var reviewItems: [ConvertedPDF] {
        manager.convertedPDFs.filter { (pdf: ConvertedPDF) -> Bool in
            let seriesEmpty = pdf.metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let authorEmpty = pdf.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let titleEmpty = pdf.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return seriesEmpty || authorEmpty || titleEmpty
        }.sorted { $0.lastModified > $1.lastModified }
    }
    
    var body: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()
            
            if reviewItems.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.green.gradient)
                    Text("Inbox is clear")
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                    Text("All comics in your library have complete metadata.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Metadata Review")
                                .font(.largeTitle.bold())
                                .foregroundColor(.primary)
                            Text("\(reviewItems.count) items need metadata matching.")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                        
                        Button {
                            Task {
                                await BackgroundMetadataEngine.shared.startEngine(manager: manager)
                            }
                        } label: {
                            Label("Auto-Match All", systemImage: "wand.and.stars.inverse")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Theme.orange)
                                .clipShape(Capsule())
                        }
                    }
                    .padding()
                    
                    List {
                        ForEach(reviewItems) { item in
                            HStack(spacing: 12) {
                                if let coverURL = manager.getCoverURL(for: item),
                                   let uiImage = UIImage(contentsOfFile: coverURL.path) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 50, height: 75)
                                        .cornerRadius(6)
                                        .clipped()
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 50, height: 75)
                                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.metadata.title.isEmpty ? item.name : item.metadata.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    
                                    Text("Missing: \(missingTags(for: item))")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                
                                Spacer()
                                
                                NavigationLink(destination: AdvancedMetadataEditorView(pdf: item)) {
                                    Text("Edit")
                                        .font(.caption.bold())
                                        .foregroundColor(Theme.orange)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Theme.orange.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.inkBorderVisible)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
    
    private func missingTags(for item: ConvertedPDF) -> String {
        var missing: [String] = []
        if (item.metadata.series?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) { missing.append("Series") }
        if (item.metadata.author?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) { missing.append("Creator") }
        if item.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("Title") }
        return missing.joined(separator: ", ")
    }
}
