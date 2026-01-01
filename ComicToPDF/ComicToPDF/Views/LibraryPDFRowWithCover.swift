import SwiftUI
import PDFKit
import UIKit

struct LibraryPDFRowWithCover: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Cover Image or Placeholder
            ZStack {
                if let data = pdf.coverImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.orange.opacity(0.1))
                    Image(systemName: "doc.richtext")
                        .font(.title)
                        .foregroundColor(.orange)
                }
            }
            .frame(width: 50, height: 70)
            .cornerRadius(4)
            .clipped()
            .onAppear {
                if pdf.coverImageData == nil {
                    conversionManager.generateCoverThumbnail(for: pdf)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(pdf.name)
                        .font(.headline)
                        .lineLimit(1)
                    if pdf.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }
                
                HStack {
                    if let collectionId = pdf.collectionId,
                       let collection = conversionManager.collections.first(where: { $0.id == collectionId }) {
                        Text(collection.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(collection.color).opacity(0.2))
                            .foregroundColor(Color(collection.color))
                            .cornerRadius(4)
                    }
                    
                    Text("\(pdf.pageCount) Pages • \(pdf.formattedSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !pdf.metadata.series.isEmpty {
                    Text(pdf.metadata.series)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
