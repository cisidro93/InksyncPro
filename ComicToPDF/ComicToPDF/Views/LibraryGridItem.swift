import SwiftUI

struct LibraryGridItem: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover Image
            ZStack {
                if let uiImage = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.1))
                    Image(systemName: "doc.richtext").font(.largeTitle).foregroundColor(.gray)
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .cornerRadius(12)
            .shadow(radius: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.1), lineWidth: 1)
            )
            
            // Metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                HStack {
                    if let collectionId = pdf.collectionId,
                       let col = conversionManager.collections.first(where: { $0.id == collectionId }) {
                        Circle().fill(colorFor(col.color)).frame(width: 8, height: 8)
                    }
                    Text(pdf.formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .cornerRadius(12)
    }
}
