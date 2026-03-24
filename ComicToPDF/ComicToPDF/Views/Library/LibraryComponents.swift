import SwiftUI
import PDFKit
import UIKit

// MARK: - LibraryGridItem
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
            .overlay(
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if pdf.contentKind == .book {
                            Image(systemName: "book.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(6)
                        } else if pdf.contentKind == .document {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(6)
                        }
                    }
                }
            )
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
        .contentShape(Rectangle())
    }
}

// MARK: - LibraryPDFRowWithCover
struct LibraryPDFRowWithCover: View {
    let pdf: ConvertedPDF
    let isSelected: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Cover Image or Placeholder
            ZStack {
                if let uiImage = conversionManager.getThumbnail(for: pdf) {
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
            .overlay(
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if pdf.contentKind == .book {
                            Image(systemName: "book.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(2)
                        } else if pdf.contentKind == .document {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                                .padding(2)
                        }
                    }
                }
            )
            .clipped()
            
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
                
                if let series = pdf.metadata.series, !series.isEmpty {
                    Text(series)
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

// MARK: - SearchFilterBar
struct SearchFilterBar: View {
    @Binding var searchText: String
    @Binding var showFilters: Bool
    
    var body: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search library...", text: $searchText)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            
            Button(action: { showFilters.toggle() }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - PDFActionViews
struct PDFActionViews: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    var body: some View {
        HStack {
            Button(action: {
                // ✅ Fix: Wrap async call in Task
                Task {
                    await conversionManager.convertComic(pdf, mangaMode: false)
                }
            }) {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            
            Button(role: .destructive, action: {
                conversionManager.deletePDF(pdf)
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
